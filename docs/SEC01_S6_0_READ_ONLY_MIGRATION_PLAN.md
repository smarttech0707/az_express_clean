# SEC-01 — S6.0 : Plan de migration des lectures `livreurs` → `driver_public` (READ-ONLY)

**Aucun code, test, Rule ou configuration n'a été modifié pour produire ce document.**
Phase strictement de planification, consécutive à S5.3.3 (reconciliation transactionnelle),
S5.3.4 (audit final de cohérence) et S5.3.5 (résolution des réserves sécurité/CI), tous
**VALIDÉ**/**VALIDÉ AVEC RÉSERVES** sans blocker.

## 1. Objet et périmètre

Préparer — sans l'exécuter — la migration progressive des lecteurs de la collection
privée `livreurs` (lisible aujourd'hui par tout utilisateur authentifié, anonymes compris,
`wallet` et `phone` inclus) vers la projection publique minimale `driver_public`
(12 champs en liste blanche, S2→S5.3.5). Périmètre : inventaire exhaustif des lecteurs
(Flutter mobile, Web, Cloud Functions), classification par faisabilité, analyse de risque
champ par champ, plan de migration par étapes, ordre recommandé, et checklist de
fermeture future des Rules `livreurs`. **Aucune migration n'est exécutée dans cette phase.**

## 2. Méthode d'inventaire

Recherche exhaustive par `grep` sur `collection('livreurs')` / `collection("livreurs")`
dans `lib/` et `functions/*.js`, complétée par la lecture du code autour de chaque
occurrence pour identifier les appels indirects (services/providers qui encapsulent la
lecture pour un appelant situé dans un autre fichier) et les champs réellement consommés
après la lecture (pas seulement l'existence de l'appel). 30 fichiers Flutter + 26 fichiers
Cloud Functions identifiés par le grep initial ont été inspectés individuellement.
Le document de planification pré-existant `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` (rédigé
avant S2, jamais implémenté au-delà de son principe) a été relu et ses tableaux
confrontés au code actuel plutôt que recopiés tels quels.

**Limites honnêtes de cette inventaire** : quelques sites de lecture indirecte (ex.
`driver_service.dart::getDriverStatus`, `firestore_service.dart::fleetDrivers`) retournent
un document/snapshot complet à un appelant non entièrement tracé dans cette phase — les
champs listés pour ces sites sont ceux visibles au point de lecture, pas nécessairement
l'usage final exhaustif chez tous les appelants. Ces incertitudes sont listées en §13.

## 3. Inventaire complet des lecteurs

### 3.1 Flutter — écrans livreur (données de son propre compte, sauf mention contraire)

| Fichier:ligne | Méthode | Type | Champs lus | Portée | Nécessité |
|---|---|---|---|---|---|
| `driver_profil.dart:44-47` | `_loadProfile()` | get | `createdAt`, `email` | soi | affichage profil |
| `driver_profil.dart:354-358` | `build()` StreamBuilder | stream | `photoUrl`, `wallet`, `deliveries`, `rating` | soi | en-tête profil (solde live) |
| `driver_location_service.dart:508-521` | `_loadRegisteredCityId()` | get | `registeredCityId` | soi | logique de zone GPS |
| `driver_dashboard.dart:123-137` | `_listenDriverDoc()` | stream | `wallet`, `avgRating`, `pendingOrderId` | soi | solde + détection de commande entrante |
| `driver_dashboard.dart:1706-1728` | `_resolveDriverPosition()` (dialog) | get (repli) | `lat`, `lng` | soi | position de repli sur le dialog d'offre |
| `driver_dashboard.dart:1808-1818` | `_accept()` (dialog) | get | `photoUrl` | soi | jointe à `acceptOrder` |
| `driver_rides_service.dart:83-89` | `fetchEarnings()` | query (sous-collection) | `wallet_transactions`: `orderId`, `amount` | soi | réconciliation gains |
| `driver_login.dart:45-48` | `_tryAutoResume()` | get | `name`, existence | soi | reprise de session |
| `driver_login.dart:109-112` | `_login()` | get | existence (`approved`) | soi | portail de connexion |
| `driver_wallet.dart:28-32` | `build()` StreamBuilder | stream | `wallet` | soi | carte solde |
| `driver_service.dart:12-14` | `getDriverStatus()` | get | `status` | variable (appelant non tracé) | lookup générique |
| `auth_service.dart:61-65` | `getDriverAuthEmail()` | query (tout `livreurs`) | `email`/`identifiant` (clé de recherche) | pré-authentification | résolution email de connexion |
| `firestore_service.dart:400-418` | `deductCommission()` | transaction | `wallet` | variable (driverId appelant) | débit commission — **voir incertitude §13** |
| `firestore_service.dart:589-593` | `fleetDrivers(ownerId)` | stream query | document complet (champs consommés par l'appelant, non tracés ici) | flotte d'un propriétaire | roster flotte |
| `firestore_service.dart:350-355` | `walletTransactions()` | stream (sous-collection) | `wallet_transactions` | soi/admin selon appelant | historique solde |
| `emulator_diagnostics.dart:31-38` | diagnostics | stream/query | `wallet` / aucun | outil de debug, hors production | N/A |

### 3.2 Flutter — admin / sous-admin / flotte / partenaires

| Fichier:ligne | Méthode | Type | Champs lus | Portée | Rôle |
|---|---|---|---|---|---|
| `admin_dashboard.dart:404-422` | `_load()` | count agrégé | aucun (filtre `isOnline` seul) | tous | admin |
| `admin_recharge_page.dart:162-180` | `build()` | stream, tous | `name`, `phone` (recherche) | tous | admin |
| `drivers_page.dart:21-27` | `build()` | stream, tous | `ownerId`, `name`, `phone`, `isOnline`, `isSuspended`, `wallet`, `identifiant` | tous | admin |
| `driver_requests_page.dart:15` | `_approve()` | get | existence | un (candidat) | admin |
| `admin_map.dart:24` | `build()` | stream, tous | `lat`, `lng`, `name`, `phone` | tous | admin |
| `admin_earnings.dart:69` | `build()` | stream, tous | `name`, `phone`, `wallet`, `isOnline` | tous | admin |
| `admin_drivers_ranking.dart:26` | `_load()` | get, tous | `name`, `phone`, `wallet`, `isOnline` | tous | admin |
| `fleet_dashboard.dart:191-194` | roster | stream, query `ownerId==` | `isOnline`, `wallet` | flotte propre | fleet owner |
| `fleet_dashboard.dart:460-463` | gains | stream, query `ownerId==` | document complet | flotte propre | fleet owner |
| `pharmacie_dashboard.dart:961-971` | `_DriverInfoCard` | stream, un doc | `name`, `phone`, `photoUrl`, `motoModel` | un (livreur assigné) | pharmacie |
| `boulangerie_dashboard.dart:707-716` | inline builder | stream, un doc | `name`, `phone`, `isOnline` | un (assigné) | boulangerie |
| `seller_dashboard.dart:1420-1440` | `_DriverSection` | stream, un doc | `name`, `phone`, `lat`, `lng`, `isOnline` | un (assigné) | vendeur |

### 3.3 Flutter — client / web / suivi / widgets partagés

| Fichier:ligne | Méthode | Type | Champs lus | Portée | Anonyme possible ? |
|---|---|---|---|---|---|
| `web_client_dashboard.dart:906-915` | `_callDriver()` | get | `phone` | un (commande propre) | non |
| `web_client_dashboard.dart:918-928` | `_rateDriver()` | get | `name` | un | non |
| `realtime_tracking_service.dart:116-120` | listener | stream | `lat`,`lng`,`heading`,`speed`,`updatedAt`,`isOnline`,`name`,`photoUrl` | un (assigné) | non |
| `tracking_service.dart:116-120` | `_start()` | stream | `lat`, `lng` | un (assigné) | non |
| `suivi_commande.dart:136-142` | `_callDriver()` | get | `phone` (pattern identique au dashboard web) | un | non |
| `suivi_commande.dart:302-308` | `itemBuilder` | get (par build, anti-pattern pré-existant, non corrigé ici) | non confirmé | un | non |
| `suivi_commande.dart:541-547` | flux de notation | get | `name` | un | non |
| `suivi_commande.dart:1328-1334` | `_listenDriver()` | stream | non confirmé (probable alignement avec `realtime_tracking_service`) | un | non |
| `customer_tracking_screen.dart:310-324` | `_loadDriverInfoById()` | get | `name`, `photoUrl`, `phone`, `avgRating` | un (assigné) | non |
| `live_marker_cache.dart:99-104` | `onlineDriversFeed()` | query, tous en ligne | dépend du mapper appelant (non entièrement tracé) | tous (en ligne) | **possible** (consommé par une carte visiteur, à confirmer avant migration) |
| `destination_picker.dart:71-100` | `_loadNearestDriver()` | query, tous en ligne (`limit 20`) | `lat`, `lng`, `name` | tous (en ligne) | non (écran atteint uniquement via un flux authentifié confirmé) |
| `conversations_page.dart:120-123` | `_driverFuture` | get (caché par tuile) | `name` | un | non |

Aucun chemin anonyme confirmé n'a été trouvé pour les 8 fichiers client/suivi inspectés en
détail (tous atteints depuis un écran authentifié) — **sauf** `live_marker_cache.dart`,
dont au moins un appelant (`client_map.dart`, hors de la liste inspectée dans cette phase)
sert potentiellement une carte publique ; à vérifier explicitement avant toute migration
de ce site précis (voir §13).

### 3.4 Cloud Functions (Admin SDK — catégorie architecturale distincte)

**Observation clé** : toutes les lectures ci-dessous passent par l'Admin SDK côté serveur,
qui **ignore entièrement les Firestore Rules**. Elles ne sont donc jamais concernées par
la fermeture future des Rules `livreurs` (§8) et ne *nécessitent* jamais une migration
vers `driver_public` pour des raisons de sécurité — seulement, éventuellement, pour des
raisons de simplicité ou de dénormalisation, ce qui est hors du périmètre sécuritaire de
SEC-01.

| Fichier | Fonction(s) | Champs lus | Catégorie de sensibilité |
|---|---|---|---|
| `index.js` (5 triggers de notification) | `notifyBroadcastDrivers`, `notifyDriverOnAssigned`, `notifyDriverOnMissionEnd`, `notifyDriverOnOrderCancelled` (×2), `notifyDriversOnNewOrder` | `fcmToken` (+ `isOnline` comme filtre) | jamais public (jeton d'appareil) |
| `driverPublicSync.js` | mécanisme de synchronisation lui-même | les 7 champs non-GPS whitelistés | N/A — c'est la source de la projection |
| `mapsProxy.js` | `assertEligibleRole` | existence, `isSuspended` | jamais public |
| `orderActions.js`, `adminBilling.js`, `partnerOrderActions.js`, `transferSettlement.js`, `driverAcceptance.js`, `adminDriverRecharge.js` | diverses (commission, remboursement, règlement, recharge) | `wallet` | jamais public (financier) |
| `adminOrderDisputes.js` | `nameOf()` (aide) | `name` seul | public — migration optionnelle, sans urgence (serveur) |
| `driverTransfer.js`, `dispatch.js` | requêtes candidats | `isOnline`, `currentCityId`, `lat`, `lng`, `updatedAt`, `isSuspended`, `isOnDelivery`, `wallet` (mixte) | **doit rester sur `livreurs`** : mélange de champs publics et privés dans un même filtre serveur, cf. `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` §4 ("Dispatch : aucun changement") |
| `driverLifecycle.js`, `assignedTimeout.js`, `driverRelease.js`, `driverDecline.js` | `currentOrderId`, `pendingOrderId`, `isOnDelivery` | jamais public |
| `azia/tools/delivery.js` | `enrichWithDriverNames()` | `name` seul | public — migration optionnelle, sans urgence |
| `driverRatings.js` | écriture de `avgRating`/`ratingCount` | ces 2 champs | N/A — c'est une partie de la source de la projection |
| `fleetDriverCreation.js` | comptage de flotte | `ownerId` | jamais public |
| `driverWalletPolicy.js`, `deliveryProofGuests.js` | vérifications | existence seule | jamais public (identité) |
| `staleDriverCleanup.js` | nettoyage planifié | `isOnline`, `updatedAt` | N/A — c'est un correcteur de la source, pas un lecteur candidat |

## 4. Classification A/B/C/D

### A — Migrable tel quel (champs 100% couverts par `driver_public`)

- `realtime_tracking_service.dart`, `tracking_service.dart` — correspondance exacte,
  **meilleur candidat de première migration**.
- `destination_picker.dart::_loadNearestDriver` (`lat`,`lng`,`name`).
- `conversations_page.dart::_driverFuture` (`name` seul).
- `web_client_dashboard.dart::_rateDriver`, `suivi_commande.dart` (flux de notation,
  `name` seul).
- `driver_dashboard.dart::_resolveDriverPosition` / `_accept` (lecture de SON PROPRE
  `lat`/`lng`/`photoUrl` — migrable, mais gain marginal : c'est déjà sa propre donnée).
- `admin_dashboard.dart` (comptages agrégés — migrable mais sans bénéfice de sécurité,
  l'admin garde un accès légitime à `livreurs` de toute façon).
- `adminOrderDisputes.js::nameOf`, `azia/tools/delivery.js::enrichWithDriverNames`
  (serveur, `name` seul — migration optionnelle, sans urgence sécuritaire).
- `live_marker_cache.dart::onlineDriversFeed` et son usage carte — **probablement A**
  mais champs exacts non confirmés (voir §13) ; si confirmé public-only, candidat fort
  vu le risque d'accès anonyme potentiel en aval.

### B — Migration hybride (séparation possible champ public / champ privé)

- `driver_profil.dart` (StreamBuilder) : `photoUrl` → `driver_public`, `wallet`/`deliveries`/
  `rating` restent sur `livreurs` (lecture propriétaire, déjà protégée par les Rules
  actuelles).
- `driver_dashboard.dart::_listenDriverDoc` : `avgRating` → `driver_public`, `wallet`/
  `pendingOrderId` restent sur `livreurs`.
- `admin_map.dart` : `lat`/`lng`/`name` → `driver_public` pour l'affichage de la carte ;
  `phone` reste une lecture `livreurs` à la demande (clic sur un marqueur), scoper le
  besoin de `phone` à un `get()` ponctuel au lieu du stream complet.
- `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart` :
  `name`/`photoUrl`/`isOnline`/`lat`/`lng` → `driver_public` ; `phone` reste dépendant de
  **D** (mécanisme `driverPhone`, non construit).
- `customer_tracking_screen.dart::_loadDriverInfoById` : `name`/`photoUrl`/`avgRating` →
  `driver_public` ; `phone` reste dépendant de **D**.

### C — À conserver dans `livreurs` (données sensibles ou privées)

Tout ce qui touche `wallet`, `ownerId`, `isSuspended`, `fcmToken`/`token`, `identifiant`,
`email`, `createdAt`, `deliveries` (compteur interne), `status`, `registeredCityId`,
`currentOrderId`/`pendingOrderId`, `currentCityId`, `motoModel` (absent de la whitelist) :

- Toute la console admin de gestion (`drivers_page.dart`, `admin_recharge_page.dart`,
  `admin_earnings.dart`, `admin_drivers_ranking.dart`) — nécessite `wallet`/`phone`/
  `isSuspended`/`identifiant` en liste, non séparable d'un affichage utile pour l'admin.
- Tout le roster et les gains flotte (`fleet_dashboard.dart`) — `wallet` + filtre `ownerId`
  intrinsèquement privés.
- `auth_service.dart::getDriverAuthEmail` — lookup pré-authentification par
  `email`/`identifiant`, structurellement incompatible avec une collection publique
  (la recherche doit se faire sur un champ jamais exposé).
- Tout le dispatch et la logique de transfert serveur (`dispatch.js`, `driverTransfer.js`)
  — mélange intentionnel de filtres publics et privés dans une même requête serveur ;
  le document `DRIVER_PUBLIC_MIGRATION_PLAN.md` (§4) l'avait déjà exclu explicitement.
- Tout le cycle de vie serveur (`driverLifecycle.js` et dépendants), toute la bookkeeping
  financière serveur (`orderActions.js`, `adminBilling.js`, `transferSettlement.js`,
  `partnerOrderActions.js`, `driverAcceptance.js`, `adminDriverRecharge.js`).
- `driver_rides_service.dart::fetchEarnings`, `firestore_service.dart::walletTransactions`
  — sous-collection `wallet_transactions`, jamais projetée et non projetable (financier).
- `deliveryProofGuests.js`, `driverWalletPolicy.js`, `mapsProxy.js::assertEligibleRole` —
  vérifications d'existence/anti-fraude liées à l'identité réelle du compte, pas à une
  donnée affichable.

### D — Migration dépendante (bloquée par un prérequis non construit)

- **Tous les sites lisant `phone` côté client** (`web_client_dashboard.dart::_callDriver`,
  `suivi_commande.dart::_callDriver`, `customer_tracking_screen.dart`, `admin_map.dart`
  au clic, `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`,
  `seller_dashboard.dart`) : dépendent du mécanisme `driverPhone` décrit dans
  `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` §4 — un champ posé **par le serveur** sur la
  commande à l'attribution, lisible par le client propriétaire de cette commande. **Ce
  mécanisme n'existe pas encore dans le code actuel** (confirmé : `driverPhone` n'apparaît
  que côté widgets Flutter consommateurs — `eta_card.dart`, `customer_tracking_screen.dart`
  — comme un champ de modèle local, jamais écrit par une Cloud Function sur `orders`).
  Tant qu'il n'est pas construit et testé, ces lectures de `phone` ne peuvent pas être
  retirées de `livreurs`.
- `pharmacie_dashboard.dart` (`motoModel`) : champ absent de la whitelist `driver_public`
  actuelle — dépend d'une décision d'extension de la liste blanche (ajouter `motoModel`
  si jugé public-safe) avant toute migration de ce champ précis.
- `driver_profil.dart` (`rating`) : nom de champ qui ne correspond à aucun des 12 champs
  actuels (`avgRating`/`ratingCount` existent, pas `rating`) — à vérifier s'il s'agit d'un
  alias/bug ou d'un champ distinct avant toute migration de ce site.

## 5. Whitelist reconstruite depuis le code (pas depuis les rapports antérieurs)

Relu directement dans `firestore.rules` (`driverPublicKeysValid()`/`driverPublicTypesValid()`,
lignes 91-110) et `functions/driverPublicSync.js` (`DRIVER_PUBLIC_FIELDS`/`GPS_PROJECTION_FIELDS`,
lignes 27-34) — identiques, confirmant l'absence de dérive depuis S5.3.4/S5.3.5 :

| Champ | Groupe | Qui l'écrit | Toujours présent ? | Fiabilité pour un lecteur |
|---|---|---|---|---|
| `lat`, `lng` | GPS | client (S4) | non — absent avant la 1ʳᵉ position, placeholder `(0,0)` filtré côté client | nécessite un fallback si absent |
| `heading`, `speed` | GPS | client (S4) | non — omis si `Position.heading`/`speed` n'est pas fini | optionnel, jamais bloquant |
| `updatedAt` | GPS | client (S4), `request.time` serveur forcé | oui si GPS déjà écrit une fois | sert aussi de mesure de péremption (dispatch utilise un seuil similaire côté `livreurs`, pas encore répliqué pour un lecteur public) |
| `name`, `photoUrl` | profil | serveur (`driverPublicSync.js`, depuis S5.3.5) | dépend de la présence sur `livreurs` au moment de la synchronisation | peut être en retard de quelques secondes (fenêtre de reconciliation déjà documentée en S5.3.3) |
| `isOnline` | disponibilité | serveur (sync) | oui dès la création | — |
| `isAvailable`, `isOnDelivery` | disponibilité | serveur (sync) ; **aucun écran livreur ne les écrit aujourd'hui** (confirmé S2, reconfirmé ici) | oui dès la création si déjà présents sur `livreurs` | champs peu utilisés par les lecteurs actuels (aucun site Flutter inventorié ici ne lit `isAvailable`/`isOnDelivery` directement depuis `livreurs`, donc aucun lecteur ne dépend de leur fiabilité pour l'instant) |
| `avgRating`, `ratingCount` | statistiques | serveur (`driverRatings.js` → sync) | oui si au moins une course notée | peut être absent pour un nouveau livreur jamais noté — nécessite un fallback d'affichage ("pas encore noté") |

Champs **absents** de la whitelist mais lus par au moins un site inventorié :
`wallet`, `phone`, `ownerId`, `isSuspended`, `fcmToken`/`token`, `identifiant`, `email`,
`createdAt`, `deliveries`, `status`, `registeredCityId`, `currentOrderId`/`pendingOrderId`,
`currentCityId`, `motoModel`, et le champ `rating` (distinct de `avgRating`, à clarifier —
voir §4/D). Aucun de ces champs ne doit être ajouté à la liste blanche sans décision
explicite et nouvelle revue de sécurité (principe déjà établi en S2 : liste blanche
stricte, pas d'ajout par défaut).

## 6. Analyse de risques par domaine

- **GPS** : déjà en production depuis S4/S4.1 (64 tests validés, cité comme référence
  historique). Risque de migration des *lecteurs* (pas de l'écriture, déjà faite) : faible
  — `driver_public` porte exactement les mêmes champs que ceux lus aujourd'hui dans
  `livreurs` par les services de suivi. Le placeholder `(0,0)` et le GPS périmé restent
  des cas à gérer côté UI, identiques à aujourd'hui (pas un risque nouveau introduit par
  la migration).
- **Disponibilité livreur** (`isOnline`/`isAvailable`/`isOnDelivery`) : `isOnline` est déjà
  largement lu par des requêtes multi-livreurs (`destination_picker`, `live_marker_cache`,
  dispatch serveur) ; la migration de ces lectures vers `driver_public` ne change pas la
  sémantique. `isAvailable`/`isOnDelivery` n'ont aucun lecteur Flutter direct identifié
  dans cet inventaire — risque nul à migrer puisqu'il n'y a rien à migrer pour ces deux
  champs côté client.
- **Profil** (`name`/`photoUrl`) : risque faible, usage très répandu et déjà conçu pour
  l'affichage public. Le seul risque réel est la fenêtre de latence serveur déjà documentée
  (S5.3.3) — un livreur qui vient de changer sa photo peut voir l'ancienne pendant
  quelques secondes sur un écran qui lirait `driver_public` au lieu de `livreurs`.
- **Statistiques** (`avgRating`/`ratingCount`) : risque faible, mêmes caractéristiques
  que le profil. Un nouveau livreur sans note doit afficher un état "pas encore noté"
  plutôt qu'une valeur par défaut trompeuse (0 étoiles) — point d'attention UI, pas de
  sécurité.
- **Téléphone** : **risque principal de toute cette migration**. C'est une donnée
  actuellement exposée via lecture directe de `livreurs.phone` par au moins 7 sites
  Flutter différents (client web, suivi commande, tracking client, 3 dashboards
  partenaires, admin au clic). Aucun ne peut migrer avant que le mécanisme `driverPhone`
  serveur (posé sur la commande à l'attribution) soit conçu, implémenté et testé — ce qui
  est un développement à part entière, pas une simple bascule de lecture. Tant que ce
  mécanisme n'existe pas, fermer `livreurs` casserait ces 7 fonctionnalités de contact
  direct. C'est la dépendance qui bloque le plus de lecteurs (catégorie D).
- **Admin et sous-admin** : toute la console admin reste légitimement sur `livreurs`
  (catégorie C) — `isAdmin()`/`hasAdminPermission('livreurs')` donne déjà un accès
  justifié et scoper ces écrans sur `driver_public` n'apporterait aucun gain de sécurité
  (l'admin voit déjà tout), seulement une complexité inutile (deux sources à maintenir en
  cohérence pour un même écran). Recommandation implicite : ne jamais migrer ces écrans.
- **Fleet** : même raisonnement — `fleet_dashboard.dart` a besoin de `wallet` et du filtre
  `ownerId`, deux données hors `driver_public` par conception. Reste en C.
- **Dispatch** : confirmé dans le code actuel (`dispatch.js`, `driverTransfer.js`) que le
  serveur mélange des filtres publics (`isOnline`, position) et privés (`isSuspended`,
  `wallet`, `isOnDelivery`) dans une même requête — migrer serait un découplage artificiel
  sans bénéfice, puisque le serveur n'est jamais soumis aux Rules. Confirme la position du
  plan pré-existant (`DRIVER_PUBLIC_MIGRATION_PLAN.md` §4, ligne "Dispatch : aucun
  changement").

## 7. Dépendances entre lecteurs

- Tous les sites `phone` (catégorie D) dépendent d'un seul prérequis commun : le
  mécanisme serveur `driverPhone` sur `orders`. Le construire une fois débloque les 7
  sites simultanément — ce n'est pas 7 dépendances séparées.
- `driver_profil.dart` (`rating`) et `pharmacie_dashboard.dart` (`motoModel`) dépendent
  chacun d'une décision ponctuelle (clarifier le champ / étendre la whitelist) avant de
  rejoindre la catégorie A ou B.
- `live_marker_cache.dart` dépend d'une vérification préalable (accès anonyme possible en
  aval ou non) avant classification définitive.
- Aucune autre dépendance croisée identifiée : les sites de catégorie A peuvent être
  migrés indépendamment les uns des autres, dans n'importe quel ordre.

## 8. Plan de migration progressive (proposé, non exécuté)

### Phase S6.1 — Lecteurs triviaux à champ unique public (`name` seul)

- Objectif : valider le chemin de lecture `driver_public` en conditions réelles sur des
  lecteurs à risque quasi nul.
- Fichiers concernés : `conversations_page.dart`, `web_client_dashboard.dart::_rateDriver`,
  flux de notation de `suivi_commande.dart`.
- Champs : `name` uniquement.
- Prérequis : aucun (champ déjà fiable, déjà servi par le serveur depuis S5.3.5).
- Risque : très faible — pire cas, un nom manquant ou légèrement périmé sur un écran
  secondaire (dialogue de notation).
- Tests nécessaires : test Flutter ciblé par écran (si une suite existe déjà pour ces
  écrans) vérifiant que le nom s'affiche correctement depuis `driver_public` ; pas de
  nouveau test Rules nécessaire (lecture déjà couverte par les 19 tests `driver-public`
  de S5.3.5).
- Rollback : revenir à la lecture `livreurs` (un seul appel Firestore à changer par site).
- Condition d'entrée : S5.3.5 validé (fait).
- Condition de sortie : les 3 écrans affichent correctement le nom en conditions réelles
  pendant une période d'observation (à définir par le porteur du projet, hors périmètre
  de cette phase de planification).

### Phase S6.2 — Services de suivi temps réel (meilleur candidat global)

- Objectif : migrer `realtime_tracking_service.dart` et `tracking_service.dart`, dont les
  champs lus (`lat`,`lng`,`heading`,`speed`,`updatedAt`,`isOnline`,`name`,`photoUrl`)
  correspondent exactement à la projection.
- Fichiers concernés : les deux fichiers, plus leurs consommateurs
  (`customer_tracking_screen.dart` reste inchangé car il ne lit pas `livreurs` directement).
- Champs : les 8 champs publics listés.
- Prérequis : aucun nouveau — tous ces champs sont déjà synchronisés et testés.
- Risque : faible à modéré — ce sont des services utilisés en continu pendant une
  livraison active ; une régression serait visible immédiatement par un client en train
  de suivre sa commande. Compensé par : repli possible sur `livreurs` en cas d'échec de
  lecture (pattern déjà recommandé par le plan pré-existant, §5 étape 4).
- Tests nécessaires : tests unitaires des deux services avec un faux Firestore simulant
  `driver_public` au lieu de `livreurs` ; test manuel de bout en bout sur un appareil
  réel pendant une livraison simulée (déjà une exigence standard du projet pour ce type
  de changement).
- Rollback : feature flag ou simple retour du nom de collection lu (changement
  localisé à une ligne par service).
- Condition d'entrée : S6.1 observé sans régression.
- Condition de sortie : suivi client fonctionnel confirmé sur plusieurs livraisons réelles
  (critère à fixer par le porteur, hors périmètre ici).

### Phase S6.3 — Requêtes multi-livreurs à champs publics

- Objectif : migrer `destination_picker.dart::_loadNearestDriver` et, après vérification
  de l'incertitude §13, `live_marker_cache.dart::onlineDriversFeed`.
- Champs : `isOnline` (filtre), `lat`, `lng`, `name`.
- Prérequis : lever l'incertitude sur l'exposition anonyme potentielle de
  `live_marker_cache.dart` (si un appelant anonyme existe réellement, vérifier que la
  règle de lecture `driver_public` — déjà `isAuth()`, pas anonyme-friendly non plus — ne
  casse pas ce cas d'usage ; si un accès véritablement anonyme est nécessaire, c'est une
  décision de règles à part, hors périmètre de cette phase).
- Risque : modéré — requêtes à fort trafic potentiel (carte), nécessitent un index
  équivalent sur `driver_public.isOnline` (à vérifier dans `firestore.indexes.json`,
  non inspecté dans cette phase — à faire avant exécution).
- Tests nécessaires : test de requête (index présent), test de régression sur l'écran de
  sélection de destination.
- Rollback : identique au pattern des phases précédentes.
- Condition d'entrée : S6.2 validé.
- Condition de sortie : carte/sélection de destination fonctionnelles sans repli observé
  pendant la période d'observation.

### Phase S6.4 — Lecteurs hybrides (séparation du champ privé restant)

- Objectif : migrer la partie publique de `driver_profil.dart` (`photoUrl`),
  `driver_dashboard.dart::_listenDriverDoc` (`avgRating`), `admin_map.dart`
  (`lat`/`lng`/`name`, en conservant un `get()` ponctuel sur `livreurs` pour `phone` au
  clic), tout en laissant les champs privés (`wallet`, `pendingOrderId`, etc.) sur
  `livreurs`.
- Prérequis : S6.1-S6.3 validés ; décision explicite sur le champ `rating` vs `avgRating`
  dans `driver_profil.dart` (voir §4/D) avant de migrer ce site précis.
- Risque : modéré — deux sources de données à synchroniser visuellement dans le même
  écran (ex. solde depuis `livreurs`, photo depuis `driver_public`) ; risque d'incohérence
  perceptible si l'un est en retard sur l'autre pendant la fenêtre de reconciliation.
- Tests nécessaires : tests d'écran vérifiant l'affichage correct des deux sources
  combinées.
- Rollback : identique.
- Condition d'entrée : S6.3 validé.
- Condition de sortie : aucune incohérence visuelle rapportée pendant la période
  d'observation.

### Phase S6.5 (bloquée) — Mécanisme `driverPhone` serveur

- Objectif : **développement à part entière**, pas une migration de lecture — construire,
  tester et déployer le champ serveur `driverPhone` sur `orders` à l'attribution, comme
  déjà spécifié dans `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` §4/§5 étape 4.
- Prérequis : décision explicite du porteur du projet (nouvelle Cloud Function ou
  extension d'une fonction d'attribution existante, avec tests dédiés — hors périmètre de
  planification S6.0, nécessite sa propre mission).
- Cette phase n'est **pas un item du plan de migration des lecteurs** au sens strict :
  elle conditionne toute la catégorie D (7 sites `phone`), qui ne peut être planifiée en
  détail (fichiers concernés, tests) qu'une fois ce mécanisme conçu.
- Risque : élevé si mal conçu — expose potentiellement un numéro à plus de clients que
  nécessaire, ou laisse une fenêtre où le numéro reste lisible après la fin de la
  livraison (expiration à spécifier).

### Hors plan (catégorie C — ne jamais migrer)

Console admin, roster/gains flotte, dispatch serveur, cycle de vie serveur, bookkeeping
financier, lookup d'authentification — listés en détail en §4/C. Resteront des lecteurs
légitimes de `livreurs` même après une fermeture complète des Rules aux autres rôles.

## 9. Ordre de migration recommandé (fondé sur le risque réel, pas une présomption)

1. **S6.1** — lecteurs `name` seul (risque quasi nul, valide le mécanisme).
2. **S6.2** — services de suivi temps réel (correspondance exacte, fort impact utilisateur
   mais zéro champ manquant).
3. **S6.3** — requêtes multi-livreurs publiques (après levée de l'incertitude anonyme).
4. **S6.4** — lecteurs hybrides (nécessite la discipline de séparation public/privé par
   écran).
5. **S6.5** — mécanisme `driverPhone` (préalable obligatoire à toute migration ultérieure
   des 7 sites `phone`), traité comme un développement séparé, pas comme une étape du
   plan de lecture.
6. **Jamais** — tout ce qui est classé C (admin, flotte, dispatch, serveur financier,
   authentification).

Justification : l'ordre suit la correspondance de champs (le plus complet d'abord), pas
le rôle de l'utilisateur — le suivi client n'est pas migré en premier parce qu'il est
visible par le client, mais parce que ses champs correspondent déjà à 100 % sans aucune
séparation ni nouveau mécanisme à construire. À l'inverse, l'admin n'est délibérément
jamais migré malgré son rôle "sensible" en apparence : c'est l'inverse — l'admin a déjà
un accès légitime complet, migrer ses écrans n'apporterait qu'une complexité de double
source sans aucun gain de confidentialité.

## 10. Tests et validation (déjà existants, à réutiliser — aucune exécution ici)

- `rules-tests/driver-public.rules.test.js` (19 tests, S5.3.5) couvre déjà la lecture
  authentifiée de `driver_public` — aucun nouveau test Rules n'est nécessaire pour les
  phases S6.1-S6.4 côté permissions, seulement des tests Flutter/service par écran migré.
- `functions/test/driverPublicSync.test.js` (32 tests) couvre déjà la fiabilité de la
  projection elle-même — pas affecté par une migration de *lecteurs*.
- Aucun test n'a été exécuté dans cette phase (strictement read-only) ; la liste ci-dessus
  documente ce qui existe déjà et pourra être étendu lors de l'exécution de chaque phase.

## 11. Rollback

Chaque phase proposée (§8) est conçue comme un changement localisé (un nom de collection
par site de lecture), avec un repli simple vers `livreurs` tant que celui-ci reste lisible
(ce qui est le cas jusqu'à la fermeture éventuelle de ses Rules, §12 — qui n'est pas
planifiée avant que toutes les phases migrables aient été observées sans régression).
Aucun rollback de données n'est nécessaire à aucune étape : `driver_public` est une
projection additive, jamais une destination d'écriture exclusive avant la toute dernière
étape (fermeture des Rules `livreurs`), qui n'est elle-même pas couverte par ce plan de
lecture.

## 12. Checklist de fermeture future des Rules `livreurs` (à vérifier avant toute fermeture — non exécutée ici)

- [ ] Toutes les phases S6.1-S6.4 exécutées et observées sans régression.
- [ ] Mécanisme `driverPhone` serveur construit, déployé et observé (phase S6.5) — sans
      quoi fermer `livreurs` casse 7 fonctionnalités de contact direct identifiées ici.
- [ ] Décision prise sur le champ `rating` (`driver_profil.dart`) et sur l'éventuelle
      extension de la whitelist pour `motoModel` (`pharmacie_dashboard.dart`).
- [ ] Incertitude sur l'exposition anonyme de `live_marker_cache.dart` levée.
- [ ] Lecteurs légitimes classés C explicitement exemptés de la fermeture : admin
      (`isAdmin()`), sous-admin avec permission `livreurs` (`hasAdminPermission`), fleet
      owner (déjà scoper par `ownerId` dans les Rules actuelles de `livreurs`), le livreur
      lui-même (`isOwner`), et tous les Cloud Functions Admin SDK (non affectés par les
      Rules de toute façon, mais à lister explicitement dans la documentation finale pour
      éviter toute confusion future).
- [ ] Couverture de test : Rules (`driver-ledger.rules.test.js`,
      `fleet-security.rules.test.js`, et tout nouveau test Rules `livreurs` post-fermeture),
      Flutter (écrans migrés), Functions (aucun changement attendu, à reconfirmer par
      exécution complète de la suite au moment de la fermeture).
- [ ] Web : toute page `lib/web/` lisant `livreurs` (seul `web_client_dashboard.dart`
      identifié ici) migrée ou explicitement exemptée.
- [ ] Pilotes (T7E) : vérifier qu'aucune lecture spécifique au pilote n'est cassée —
      **non inspecté dans cette phase**, à faire explicitement avant fermeture (cette
      phase n'a pas touché au pilote T7E, conformément aux règles absolues).
- [ ] Observabilité : un compteur de repli (lecture `livreurs` par un rôle désormais
      censé lire `driver_public`) existe et est à zéro ou quasi nul pendant une période
      d'observation définie — mécanisme déjà recommandé par
      `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` §5 étape 5, non implémenté à ce jour.
- [ ] Version minimale applicative : `MinVersionService` déjà existant pour le rôle
      `driver` (`config/app_versions`) — à étendre aux rôles `client`/`partner` avant
      fermeture, sans quoi les anciennes versions perdent le suivi (cf. plan pré-existant
      §6).
- [ ] Validation manuelle explicite du porteur du projet — aucune fermeture de Rules ne
      doit être automatique ou implicite.

## 13. Risques résiduels et incertitudes

- **`live_marker_cache.dart::onlineDriversFeed`** : champs exacts consommés par son
  mapper (`liveDriverSnapshotFromQuery`) non ouverts dans cette phase ; au moins un
  appelant potentiellement anonyme (`client_map.dart`, hors des fichiers explicitement
  inspectés) mentionné par un des forks d'inventaire sans confirmation directe — **à
  vérifier avant toute migration de ce site**.
- **`suivi_commande.dart`** : 2 sites (`itemBuilder` à la ligne ~302, `_listenDriver()` à
  la ligne ~1328) dont les champs exacts n'ont pas pu être confirmés dans le temps alloué
  à cette phase — probable alignement avec `realtime_tracking_service.dart` (champs
  publics) au vu du contexte (affichage de liste, panneau de suivi), mais non vérifié
  ligne à ligne.
- **`driver_service.dart::getDriverStatus`** et **`firestore_service.dart::fleetDrivers`** :
  retournent un document/snapshot à un appelant non entièrement tracé dans cette phase —
  la classification (C, par prudence) pourrait se révéler trop conservatrice si l'usage
  réel chez l'appelant ne touche que des champs publics ; à revérifier si ces sites
  deviennent candidats à une migration.
- **`firestore_service.dart::deductCommission`** (lignes 400-418) : incident relevé en
  cours d'inventaire, **hors périmètre des lectures `driver_public`** mais signalé par
  transparence — ce code client semble écrire directement `wallet` depuis Flutter via une
  transaction, ce qui semble contredire l'invariant documenté (`.claude/rules/payments-wallet.md` :
  « Aucun crédit/débit cross-user depuis Flutter », commission prélevée uniquement côté
  serveur dans `acceptOrder`). **Non corrigé** (hors périmètre read-only de S6.0, et hors
  des 3 réserves de S5.3.5) — signalé ici pour qu'une décision explicite soit prise lors
  d'une phase dédiée, pas pour être traité silencieusement.
- **Champ `rating` vs `avgRating`** (`driver_profil.dart`) : nom de champ distinct de ceux
  de la whitelist, cause et usage réels non élucidés dans cette phase.
- **`driver_public.updatedAt` comme mesure de péremption pour un lecteur public** :
  le dispatch serveur utilise déjà un seuil de péremption GPS (`STALE_MINUTES`) sur
  `livreurs.updatedAt`, mais aucun lecteur Flutter côté `driver_public` n'implémente
  aujourd'hui une logique équivalente de péremption — à spécifier lors de la conception
  détaillée de S6.2, pas dans cette phase de planification.

## 14. Verdict

**PLAN VALIDÉ AVEC RÉSERVES.**

L'inventaire est suffisamment complet pour engager S6.1 (lecteurs `name` seul, risque
quasi nul) une fois une décision explicite prise. Les réserves portent sur : la
dépendance bloquante du mécanisme `driverPhone` pour toute la catégorie D (la plus
nombreuse par nombre de sites), deux incertitudes de champs non confirmées
(`live_marker_cache.dart`, deux sites de `suivi_commande.dart`), une décision de
nommage de champ en attente (`rating`), et un incident signalé hors périmètre
(`deductCommission`). Aucune de ces réserves n'empêche de commencer la planification
détaillée de S6.1 ; elles doivent en revanche être levées avant S6.4 et impérativement
avant toute fermeture des Rules `livreurs` (§12).

Ce verdict n'autorise pas l'implémentation de S6.1 ni d'aucune autre phase.

**STOP après ce rapport. Pas d'enchaînement automatique sur S6.1.**
