# AZ Express — Dictionnaire de données Firestore

**Date** : 2026-07-01. Schéma réel de production, sous les noms de collections **réels** — aucun renommage effectué (voir `CLAUDE.md`, section "Firestore — schéma réel (ne jamais renommer en prod)" pour la raison : un renommage casserait ~40 Cloud Functions, toutes les règles, tous les index et tous les écrans existants sur une application avec des données réelles).

**Méthode** : chaque collection ci-dessous est extraite directement de `firestore.rules` (source de vérité pour les contraintes de champs) et croisée avec `firestore.indexes.json` (index composites réels) et le code Dart/Cloud Functions déjà audité au fil de cette session. Les champs marqués **(règle)** sont garantis par une contrainte Firestore Rules ; les autres sont documentés d'après le code applicatif et peuvent évoluer sans que les règles ne le forcent.

**Ce document ne remplace pas** une revue de schéma humaine — c'est une photographie fidèle, pas une recommandation de refonte.

---

## Sommaire par domaine

- [Identité & rôles](#identité--rôles) : `admins`, `clients`, `livreurs`, `sellers`, `restaurants`, `restaurant_owners`, `boulangeries`, `pharmacies`, `pharmacie_credentials`, `fleet_owners`, `ekbine_agents`, `service_providers`
- [Demandes d'inscription/approbation](#demandes-dinscriptionapprobation) : `driver_requests`, `seller_requests`, `restaurant_requests`, `boulangerie_requests`, `pharmacie_requests`, `real_estate_agent_requests`
- [Commandes](#commandes) : `orders`, `ekbine_orders`, `boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`
- [Marketplace](#marketplace) : `marketplace_products`, `marketplace_favorites`, `marketplace_chats`, `marketplace_reports`, `boutique_products`
- [Immobilier](#immobilier) : `real_estate_agents`, `real_estate_listings`, `real_estate_visit_requests`, `real_estate_categories`, `locations` (legacy, à réconcilier), `residences`
- [Wallet & paiements](#wallet--paiements) : `wallet_transactions` (top-level + sous-collections), `withdrawal_requests`, `recharge_requests`, `commissions`
- [Géographie](#géographie) : `zones_livraison`, `places`
- [Communication](#communication) : `chats`, `ekbine_chats`, `notifications`, `support_tickets`, `contact_messages`
- [Avis & signalements](#avis--signalements) : `reviews`, `service_reviews`, `sos_alerts`, `delivery_reports`
- [Services locaux](#services-locaux) : `services`
- [Configuration](#configuration) : `config`, `app_config`
- [Sécurité & audit (CF-only)](#sécurité--audit-cf-only) : `audit_logs`, `request_logs`, `security_events`, `rate_limits`, `invalid_fcm_tokens`, `dispatch_metrics`, `driver_rankings` (schéma mort)
- [AZ IA](#az-ia) : `ai_conversations`, `ai_pending_actions`

---

## Identité & rôles

Pas de collection `users` unique — le rôle est déterminé par la collection qui contient le document. Aucun `setCustomUserClaims` Firebase Auth n'est utilisé ; le contrôle d'accès repose sur `exists()`/`get()` dans les règles.

### `admins/{adminId}`
- Champs : `role` ('super'|'sub'), `isActive` (bool, défaut true), `permissions` (string[], clés de section — 'livreurs','commandes','gains','restaurants', etc., sous-admins uniquement), `email`, `phone` (optionnel, active la 2FA SMS), `otpHash`/`otpCode`/`otpExpiry`/`otpAttempts` (2FA), `fcmToken`.
- Règles : lecture propriétaire/admin ; écriture réservée au super-admin, sauf les champs OTP qu'un admin peut modifier lui-même.
- Relation : `adminId` = UID Firebase Auth (email/mot de passe).

### `clients/{clientId}`
- Champs **(règle)** : `wallet` (int, ne peut être modifié par le propriétaire que par diminution — paiement direct côté client), `fakeOrderCount` (int, protégé), `cashOnDeliveryEnabled` (bool, protégé).
- Autres champs connus : `fcmToken`, `currentUid`, `name`/`phone`/`email` (si compte email optionnel créé).
- Sous-collection `wallet_transactions/{txId}` : `type`/`amount`(int)/`description`/`orderId`/`createdAt`/`provider`/`txId` — création client limitée à ces clés, `update` totalement interdit (append-only).
- Sous-collection `favorite_providers/{providerId}` : propriétaire uniquement.
- Relation : `clientId` = UID Firebase Auth (anonyme par défaut).

### `livreurs/{livreurId}`
- Champs **(règle)** : `wallet` (int, diminution seule côté propriétaire — déduction commission), `isOnline`, `isOnDelivery`, `isAvailable`, `isSuspended`, `lat`/`lng`, `updatedAt`, `pendingOrderId`.
- Lecture publique à tout utilisateur authentifié (y compris anonyme — nécessaire pour la carte client).
- Sous-collection `wallet_transactions` : même contrat que `clients`.

### `sellers/{sellerId}`
- Champs **(règle)** : `wallet` (protégé côté propriétaire), `subscriptionStatus`.
- Autres : `name`, `phone`, `type`, `isActive`, `vipStatus`, `vipExpiresAt`.

### `restaurants/{restaurantId}`
- Écriture admin uniquement (pas d'auto-édition propriétaire directe sur ce document — le propriétaire édite via `restaurant_owners` + sous-collection `menu`).
- Sous-collection `menu/{menuId}` : lecture publique, écriture admin ou propriétaire (vérifié via `restaurant_owners/{uid}.restaurantId == restaurantId`).
- Sous-collection `menus/{menuId}` : **legacy, conservée pour compatibilité**, écriture admin seule.
- Champs connus : `name`, `address`, `category` (texte libre), `isOpen` (bool), `vipStatus`, `subscriptionStatus`, `wallet`, `lat`/`lng`, `fcmToken`.

### `restaurant_owners/{ownerId}`
- Mappe un UID propriétaire → `restaurantId`. Lecture propriétaire/admin, écriture admin seule.

### `boulangeries/{boulangerieId}`
- Champs **(règle)** : `wallet`, `subscriptionStatus`, `subscriptionExpiresAt`, `vipStatus`, `vipExpiresAt`, `vipStartedAt` — tous protégés contre l'auto-édition (le propriétaire peut éditer le reste de son profil).
- Sous-collection `menu_items/{itemId}` : `name`, `price`, `description`, `category` (liste hardcodée : Pains/Viennoiseries/Gâteaux/Boissons/Formules/Autres), `isAvailable`.

### `pharmacies/{pharmacieId}`
- Champs connus : `name`, `address`, `phone`, `hours`, `lat`/`lng`, `isOnDuty` (bool), `mustChangePassword` (bool), `currentUid` (lie la session Firebase anonyme au compte).
- **`password`/`accessCode` interdits en écriture directe** (corrigé cette session — voir section Sécurité de `CLAUDE.md`) : le mot de passe vit désormais uniquement dans `pharmacie_credentials`.
- Lecture publique (authentifié, anonyme inclus) pour ne pas casser le parcours client de recherche de pharmacie de garde.

### `pharmacie_credentials/{pharmacieId}` — **nouveau (2026-07-01)**
- `hash` (string, `salt:hash` scrypt), `updatedAt`.
- **CF-only** (`allow read, write: if false`) — alimenté uniquement par `pharmacieLogin()`/`setPharmaciePassword()`.

### `fleet_owners/{fleetId}`
- Champs **(règle)** : `wallet`, `subscriptionStatus`, `subscriptionExpiresAt`, `vipStatus`, `vipExpiresAt` — protégés.

### `ekbine_agents/{agentId}`
- Champs **(règle)** : `isVerified` (bool, doit être `false` à la création), `isSuspended` (doit être `false` à la création), `walletBalance` (int, doit être `0` à la création, protégé ensuite — crédité uniquement via `ekClientConfirmOrder`), `totalCompleted` (doit être `0` à la création), `rating`/`ratingCount` (modifiables uniquement par le client d'une commande `completed` de cet agent, incrément de 1 exactement).
- Lecture publique (authentifié).

### `service_providers/{providerId}` (artisans)
- Champs connus : `artisanUid` (lié une seule fois par l'artisan lui-même, immutable ensuite), `photos` (modifiable par le propriétaire une fois lié), `artisanPin` (PIN de connexion, géré via `resetAccountPassword` CF).
- **Limitation architecturale documentée dans les règles elles-mêmes** : le login artisan utilise `signInAnonymously()`, empêchant `isRealUser()` — même pattern historique que l'ancien problème pharmacie (règle notée "Phase 5 : migrer vers Cloud Function artisanLogin()", jamais fait).

---

## Demandes d'inscription/approbation

Pattern uniforme répété 6 fois : `create` par le demandeur (`uid` doit correspondre), `read` par le demandeur ou l'admin, `update`/`delete` admin seul. Toutes indexées `(status ASC, createdAt DESC)`.

| Collection | Rôle créé après approbation |
|---|---|
| `driver_requests/{id}` | → `livreurs` |
| `seller_requests/{id}` | → `sellers` |
| `restaurant_requests/{id}` | → `restaurants` + `restaurant_owners` |
| `boulangerie_requests/{id}` | → `boulangeries` (lecture admin seule, contrairement aux autres) |
| `pharmacie_requests/{id}` | → `pharmacies` (lecture admin seule) |
| `real_estate_agent_requests/{id}` | → `real_estate_agents` (jalon M6) |

---

## Commandes

### `orders/{orderId}` — collection polymorphe centrale
Partagée par livraison, courses, restaurant, marketplace, pharmacie via les champs `type`/`sellerType`/`pharmacieId`. **Ne jamais scinder en collections séparées sans plan de migration dédié** (voir `CLAUDE.md`).

Champs **(règle)** à la création : `clientId` (== auteur), `budget` (int, ≥ 500), `isPaid` (doit être `false`), `status` (doit être `'pending'`), `driverId` (doit être absent).

Cycle de statut **(règle, state machine explicite)** : `pending → assigned → accepted → picked_up → delivered`, ou `pending → cancelled` (client). Transitions autorisées : livreur fait avancer `assigned→accepted→picked_up→delivered` (avec `isPaid→true` possible seulement au passage `picked_up→delivered` pour le cash) ; client peut annuler depuis `pending`, ou noter (`rating`/`sellerRating`) depuis `delivered`.

Autres champs connus (non contraints par les règles, documentés par le code) : `description`, `shoppingBudget`, `items[{name,budgetFcfa}]` (additif, jalon M4), `latitude`/`longitude`, `deliveryAddress`/`deliveryLatitude`/`deliveryLongitude`, `pickupAddress`/`pickupLatitude`/`pickupLongitude`, `type`, `sellerId`/`sellerName`/`sellerType`, `pharmacieId`/`pharmacieName`, `clientName`/`clientPhone`, `paymentMethod` ('cash'|'wallet'), `forSelf`, `deliveryMode` ('standard'|'express'), `recipientName`/`recipientPhone`, `pickupContactName`/`pickupContactPhone`, `pickupZone`/`deliveryZone`, `deliveredLat`/`deliveredLng`/`deliveredAt`, `deliveryPhoto`, `driverAcceptanceSelfie`/`driverPhotoUrl`, `voiceMessage`, `medicineAmount`, `notifiedDriverIds[]`, `cancelReason`/`cancelledAt`, `source` ('ai_chat' pour les commandes créées par AZ IA), `createdAt`.

Index : `(clientId,createdAt)`, `(clientId,status,createdAt)`, `(status,createdAt)`, `(driverId,status)`, `(driverId,createdAt)`, `(sellerId,createdAt)`, `(sellerType,createdAt)`, `(pharmacieId,createdAt)`, `(pharmacieId,status,createdAt)`.

### `ekbine_orders/{orderId}`
Collection dédiée Ekbine (moto-taxi/services financiers), séparée de `orders` car son cycle de vie et son modèle de commission sont différents.

Champs **(règle)** : `clientId`, `status` (doit être `'pending'` à la création, `agentId` absent), `amount` (int ≥ 100). Cycle : `pending → assigned/awaiting_deposit → in_progress → proof_sent → completed` (le passage à `completed` **doit** passer par la Cloud Function `ekClientConfirmOrder` — interdit en écriture directe, pour créditer le wallet agent atomiquement) ou `cancelled`/`disputed`.

Autres champs : `clientName`/`clientPhone`, `operator`, `serviceId`/`serviceLabel`, `beneficiaryNumber`, `totalPaid`, `paymentMethod`, `fee` (toujours `0` — pas de commission Ekbine, décision produit), `commissionAZ`/`agentEarning`, `proofUrl`/`depositProofUrl`, `message`, `cancellationReason`.

Index : `(clientId,createdAt)`, `(clientId,status,createdAt)`, `(status,operator,createdAt)`, `(agentId,status,createdAt)`.

### `boutique_orders/{orderId}`, `blanchisserie_orders/{orderId}`, `eau_boissons_orders/{orderId}`
Trois collections au schéma identique pour des services simples (boutique en ligne, blanchisserie, eau/boissons) — distinctes de `orders`, non auditées en détail dans les prompts précédents.
- Champs **(règle)** : `clientId` (== auteur), `status` (doit être `'pending'` à la création), `totalAmount` (int > 0, si présent).
- Lecture : client propriétaire ou admin. Update/delete : admin seul.

---

## Marketplace

### `marketplace_products/{productId}`
Champs **(règle)** : `sellerId` (== auteur à la création), `status` ('active'|'hidden'|'sold' — seuls 'active'/'hidden' autorisés à la création), `price` (int > 0), `views`/`favoritesCount` (modifiables indépendamment par n'importe quel utilisateur authentifié — compteurs publics).
Autres champs : `title`, `description`, `category`/`subcategory` (codés en dur côté client, `mp_constants.dart` — dette documentée), `brand`, `condition` ('new'|'like_new'|'used'), `storage`/`ram`/`color`/`battery` (champs plats spécifiques téléphone, pas de variantes génériques), `images[]`, `city`, `lat`/`lng`, `sellerName`/`sellerPhone`/`sellerCity`/`sellerVerified`/`sellerVipStatus`, `createdAt`.
Visibilité : les annonces `'hidden'` ne sont visibles que par leur vendeur et les admins.
Index : `(status,createdAt)`, `(status,category,createdAt)`, `(sellerId,createdAt)`.

### `marketplace_favorites/{userId}`
Doc id = UID. Sous-collection `items/{itemId}`. Propriétaire uniquement.

### `marketplace_chats/{chatId}/messages/{msgId}`
`chatId` au format `mp_{productId}_{buyerUid}`. Champ `sellerId` sur le doc chat. Messages : `senderId` (== auteur), `type` ('text'|'audio').

### `marketplace_reports/{reportId}`
Signalement d'abus (pas des avis) : `productId`, `reportedBy` (== auteur), `reason`. Lecture/traitement admin seul — **aucun écran de modération n'existe encore côté admin** (dette documentée).

### `boutique_products/{productId}`
Catalogue simple distinct de Marketplace : `sellerId` (== auteur), lecture publique, édition/suppression par le vendeur propriétaire ou l'admin.

---

## Immobilier

### `real_estate_agents/{agentId}`, `real_estate_agent_requests/{requestId}`, `real_estate_listings/{listingId}`, `real_estate_visit_requests/{requestId}`, `real_estate_categories/{categoryId}`
Module M6 (livré 2026-07-01) — détail complet déjà dans `CLAUDE.md` section Immobilier. `real_estate_categories` est **Firestore-driven dès le départ** (pas de liste codée en dur, contrairement à Marketplace). `real_estate_visit_requests` est CF-only, cycle `pending→proposed→confirmed/declined/cancelled`.

### ⚠️ `locations/{locationId}` — système parallèle non réconcilié
Collection **préexistante, simple**, lue par `LocationsPage` (carte "Maisons à louer") : `title`, `address`, `price`, `rooms`, `photoUrl`, `description`, `isAvailable` (bool). Lecture publique, écriture admin. **Aucun rapport avec `real_estate_listings`** — pas d'agent vérifié, pas de workflow de visite. Découverte en construisant M6, non résolue (voir `CLAUDE.md` et `AUDIT_FINAL.md`).

### `residences/{residenceId}`
Collection distincte pour "Résidences Meublées" (`ResidencesPage`) — lecture publique, écriture admin. Schéma détaillé non audité ; possible chevauchement supplémentaire avec Immobilier, non vérifié.

---

## Wallet & paiements

### `wallet_transactions/{txId}` (top-level)
Flux FeexPay (recharge/retrait) : `userId`, `userType`, `amount`, `status` ('pending'|'completed'|'error'|'cancelled'|'failed'), `paymentMethod` (opérateur), `provider` ('FeexPay'), `phone`, `credited` (bool), `validatedAt`, `feexpayToken`/`feexpayUrl`, `errorMessage`, `source` ('ai_chat' si initié par AZ IA). **Append-only** : `update` totalement interdit dans les règles, `delete` admin seul.
Index : `(userId,createdAt)`.

### Sous-collections `{clients|livreurs|sellers}/{uid}/wallet_transactions/{txId}`
Historique par utilisateur — **vocabulaire `type` incohérent d'une écriture à l'autre** ('recharge'|'withdrawal'|'refund'|'payment'|'purchase'|'sale'|'debit'|'earning', jamais le même jeu de valeurs selon l'écran d'origine — dette documentée dans `CLAUDE.md`). Append-only (`update: if false`).

### `withdrawal_requests/{reqId}`
`userId` (== auteur), `status` (doit être `'pending'` à la création), `amount` (int, 500–500000). Cycle réel (hors règles, côté Cloud Function) : `pending → processing → sent`, ou `pending_manual`/`failed`.

### `recharge_requests/{reqId}`
`userId` (== auteur), `status` ('pending' à la création), `amount` (int ≥ 100). Géré par admin.

### `commissions/{commissionId}`
Journal d'audit des commissions livreur : `orderId`, `driverId`, `amount`, `deliveryFee`, `paymentMethod`. Lecture admin seule, **écriture CF-only** (`allow write: if false`).

---

## Géographie

### `zones_livraison/{zoneId}`
`name`, `type` ('ville'|'quartier'|'village'|'secteur'), `lat`/`lng`, `isActive`, `order` (pour le tri manuel). Lecture authentifié, écriture admin (CRUD complet déjà via `admin_zones_page.dart`). Portée actuelle : Côte d'Ivoire/Abengourou uniquement — pas de couche pays/région au-dessus (voir `CLAUDE.md` section multi-pays).
Index : `(order,name)`, `(type,order,name)`, `(isActive,order)`.

### `places/{placeId}`
Base de lieux locale (autocomplétion adresse) : `name`, `latitude`/`longitude` (number, requis), `searchCount`/`updatedAt` (seuls champs modifiables par un utilisateur non-admin, pour incrémenter la popularité).

---

## Communication

### `chats/{chatId}/messages/{messageId}`
Chat générique avec `participants[]` sur le doc parent (contrairement à `ekbine_chats`/`marketplace_chats` qui dérivent l'appartenance différemment). Utilisé pour le chat driver↔client générique (`chat_page.dart`). `senderId` (== auteur) requis à la création d'un message.

### `ekbine_chats/{orderId}/messages/{msgId}`
Appartenance dérivée de `ekbine_orders/{orderId}.clientId`/`.agentId` (pas de champ `participants` séparé). `senderId`/`senderRole`/`type` ('text'|'audio') requis.

### `notifications/{notifId}`
Notifications persistantes par utilisateur : `userId`, `read`/`readAt` (seuls champs modifiables par le propriétaire). Création CF-only (`allow create: if isAdmin()` — en pratique via triggers Cloud Functions, pas directement par ce nom que par les admins). **Distinct de** `clients/{uid}/notifications` (sous-collection utilisée par `notification_center.dart`, non visible dans les règles ci-dessus car probablement couverte par une règle plus générale ou à vérifier — incohérence potentielle à clarifier).

### `support_tickets/{ticketId}`
`userId` (== auteur), `status` (doit être `'open'` à la création), `messages[]` (le propriétaire peut ajouter des messages sans changer le statut — **mais aucun écran client n'affiche les réponses d'un agent**, dette UX documentée), `subject`, `category` (enum fixe : Livraison/Paiement-Wallet/Commande/Compte/E-Kbine/Marketplace/Autre), `screenshotUrl`, `source` ('ai_chat' si créé par AZ IA).
Index : `(status,createdAt)`.

### `contact_messages/{msgId}`
Formulaire de contact web : `email` (≤200 car.), `message` (≤2000 car.). Lecture/traitement admin seul.

---

## Avis & signalements

### `reviews/{reviewId}`
`sellerId`, `rating` (number, 1–5), `createdAt`. Lecture authentifié, update/delete admin seul.

### `service_reviews/{reviewId}`
`providerId`, `clientId` (== auteur), `rating` (1–5), `createdAt` — pour les artisans/prestataires de service.

### `sos_alerts/{alertId}`
Alerte d'urgence client ou livreur : `status` (doit être `'active'` à la création), `lat`/`lng`, `timestamp`, plus `clientId` **ou** `driverId` selon l'émetteur. Lecture/traitement admin seul.

### `delivery_reports/{reportId}`
Signalement de difficulté de livraison par un livreur : `orderId`, `driverId` (== auteur), `difficulty`, `createdAt`. Lecture/traitement admin seul.

---

## Services locaux

### `services/{serviceId}`
Catalogue de services locaux (artisans, etc.) — lecture publique, écriture admin. Schéma détaillé non audité en profondeur.

---

## Configuration

### `config/{configId}`
**Publique en lecture** (`allow read: if true` — pas même besoin d'authentification) : couleurs/textes UI, pas de données financières. Contient `config/commission` (`commissionBasic`, `commissionStandard`, `threshold` — pilote la commission livreur).

### `app_config/{configId}`
Configuration business sensible (seuils, etc.) — lecture ET écriture admin uniquement, contrairement à `config` qui est public en lecture. **Deux collections de config distinctes à ne pas confondre.**

---

## Sécurité & audit (CF-only)

Toutes les collections suivantes ont `allow write: if false` dans les règles — écriture exclusivement via Cloud Functions (Admin SDK, qui contourne les règles) :

- **`audit_logs/{logId}`** — `userId`, `userType`, `action`, `targetId`, `amount`, `status`, `metadata{}`, `createdAt`. Alimenté par le helper `logAudit()`. Index : `(action,createdAt)`.
- **`request_logs/{logId}`** (2026-07-02) — `requestId`, `functionName`, `userId`, `durationMs`, `status` ('success'|'error'), `errorCode`, `errorMessage`, `createdAt`. Diagnostic technique haut-volume (pas une piste d'audit métier, distinct d'`audit_logs`), alimenté par `functions/observability.js:withObservability()` — utilisé uniquement par les nouvelles Cloud Functions à partir de cette date, pas rétrofité sur les fonctions existantes. Lecture super-admin uniquement.
- **`security_events/{eventId}`** — `userId`, `eventType`, `severity` ('low'|'medium'|'high'|'critical'), `description`, `resolved` (bool, seul champ modifiable par un admin). Index : `(severity,resolved)`, `(eventType,createdAt)`.
- **`rate_limits/{key}`** — clé `{uid}_{action}`, `requests[]` (timestamps), `updatedAt`. Lecture ET écriture interdites même à l'admin (`allow read, write: if false`).
- **`invalid_fcm_tokens/{docId}`** — nettoyage asynchrone, jamais lu/écrit par un client.
- **`dispatch_metrics/{metricId}`** — lecture admin seule, écriture CF-only.
- **`driver_rankings/{driverId}`** — ⚠️ **schéma mort** : existe dans les règles (lecture authentifié, écriture admin) mais n'est écrit ni lu nulle part dans le code applicatif. Candidat à suppression ou à activation, pas à laisser en l'état indéfiniment.

---

## AZ IA

### `ai_conversations/{ownerId}/messages/{messageId}`
`conversationId`, `role` ('user'|'assistant'), `content`, `createdAt`. Lecture propriétaire/admin, **écriture CF-only** (`allow write: if false`) — alimenté uniquement par `azIaChat`.

### `ai_pending_actions/{actionId}`
`uid`, `conversationId`, `toolName`, `toolInput{}`, `summaryFr`, `amount`, `status` ('pending'|'completed'|'cancelled'|'expired'), `expiresAt` (5 min après création), `createdAt`/`resolvedAt`. Lecture propriétaire/admin, **écriture CF-only** — alimenté par `createPendingAction()`/`aiConfirmAction`/`aiCleanupExpiredPendingActions`.
Index : `(status,expiresAt)`.

---

## Incohérences relevées pendant la compilation de ce document (à vérifier, pas corrigées)

1. **Deux collections `config`** (`config` public en lecture vs. `app_config` admin-only) — le partage des responsabilités entre les deux n'est pas documenté ailleurs que par leur nom ; à clarifier si un nouveau champ de configuration doit être ajouté.
2. **`notifications` (top-level) vs. `clients/{uid}/notifications` (sous-collection)** — `notification_center.dart` lit la sous-collection (déjà documenté dans `CLAUDE.md`), mais une collection top-level `notifications/{notifId}` existe aussi dans les règles avec un contrat différent (`userId` en champ plutôt qu'un chemin de sous-collection). Les deux semblent servir des besoins différents (peut-être l'une pour FCM/push générique, l'autre pour l'historique client) mais ça n'a pas été vérifié dans cette session — à clarifier avant d'ajouter un nouveau type de notification.
3. **`residences` et `locations`** pourraient chevaucher avec le nouveau module Immobilier (`real_estate_listings`) au-delà du chevauchement déjà documenté avec `locations` — non vérifié en détail.
4. **`driver_rankings`** est un schéma mort — à supprimer des règles ou à activer, pas à laisser indéfiniment en zone grise.
