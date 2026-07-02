# AZ Express — Firestore Security Rules : documentation complète

**Date** : 2026-07-01. Documente `firestore.rules` tel qu'il existe réellement (756 lignes, ~70 blocs `match`) — complète `FIRESTORE_SCHEMA.md` (organisé par collection) avec une vue **par rôle** et une explication de chaque pattern de sécurité utilisé. Aucune règle n'a été réécrite pour produire ce document.

---

## 1. Principe général déjà en place

Le fichier ouvre sur `service cloud.firestore { match /databases/{database}/documents { ... } }` — **tout accès non explicitement autorisé est refusé par défaut** (comportement natif Firestore, pas besoin d'une règle "deny all" explicite). Une seule règle publique existe dans tout le fichier : `config/{configId}` en lecture (`allow read: if true`) — délibérée et documentée en commentaire ("publique : couleurs, textes UI — pas de données financières"). **C'est la seule exception au principe zero-trust dans toute la base, et elle est intentionnelle.**

## 2. Fonctions utilitaires (le socle du RBAC actuel)

```
isAuth()        → request.auth != null
uid()           → request.auth.uid
isOwner(id)     → isAuth() && uid() == id
isRealUser()    → isAuth() && provider != 'anonymous'  (exclut les comptes anonymes)
isAdmin()       → isAuth() && admins/{uid} existe && isActive != false
isSuperAdmin()  → isAdmin() && admins/{uid}.role != 'sub'
unchanged(f)    → request.resource.data[f] == resource.data[f]   (interdit de modifier un champ)
notPresent(f)   → le champ n'est pas présent dans l'écriture entrante
isPharmacieOwnerOfOrder() → vérifie que pharmacies/{pharmacieId}.currentUid == uid() pour la commande visée
```

Ces 8 fonctions couvrent l'intégralité du contrôle d'accès du fichier — pas de logique dupliquée collection par collection.

## 3. Matrice de permissions par rôle (vue transverse)

| Rôle | Comment il est identifié | Ce qu'il peut faire au-delà de la lecture publique |
|---|---|---|
| **Anonyme** (client avant inscription) | `isAuth()` vrai, `isRealUser()` faux | Lecture des listings publics (restaurants, pharmacies, marketplace actif, real_estate actif, zones, places) ; création de commandes (`orders`, `ekbine_orders`, `boutique_orders`...) est bloquée par `isRealUser()` sur la plupart des collections de commande |
| **Client** (`clients/{uid}`) | `isOwner(clientId)` | Gère son propre profil (hors `wallet`/`fakeOrderCount`/`cashOnDeliveryEnabled`, protégés) ; crée/annule ses commandes ; note après livraison ; lit son historique wallet (append-only) |
| **Livreur** (`livreurs/{uid}`) | `isOwner(livreurId)` | Met à jour sa position/disponibilité (jamais son `wallet` sauf diminution — déduction commission) ; fait avancer le statut d'une commande qui lui est assignée selon la state machine |
| **Vendeur** (`sellers/{uid}`) | `isOwner(sellerId)` | Gère `marketplace_products` dont il est propriétaire ; `wallet` protégé |
| **Restaurant/Boulangerie** | Via `restaurant_owners/{uid}.restaurantId` ou `isOwner(boulangerieId)` | Gère son menu (sous-collection) ; champs financiers (`wallet`, `subscriptionStatus`, `vipStatus`...) protégés |
| **Pharmacie** | Session liée via `pharmacies/{id}.currentUid == uid()` | Peut mettre à jour uniquement `currentUid` (binding de session) ; mot de passe jamais accessible en écriture directe (`pharmacie_credentials`, CF-only) |
| **Agent E-Kbine** (`ekbine_agents/{uid}`) | `isOwner(agentId)` | Fait avancer le statut d'une commande qui lui est assignée ; `walletBalance` protégé (crédité uniquement via `ekClientConfirmOrder`, une Cloud Function) |
| **Agent Immobilier** (`real_estate_agents/{uid}`) | `isOwner(agentId)` | Gère ses annonces (`real_estate_listings`) ; `isVerified`/`isActive` protégés (admin seul) |
| **Support/Modérateur/Comptable** | **N'existent pas comme rôles distincts** | Voir section 6 — pas encore modélisés, cohérent avec `CLAUDE.md` section RBAC |
| **Sous-admin** (`admins/{uid}.role == 'sub'`) | `isAdmin()` vrai, `isSuperAdmin()` faux | `isAdmin()` donne accès à **toutes** les opérations réservées aux admins dans ce fichier — les règles Firestore ne distinguent PAS super-admin de sous-admin sur la plupart des collections (voir section 6) ; la granularité par section (`admins/{uid}.permissions[]`) est appliquée côté **Flutter/UI**, pas dans les règles elles-mêmes |
| **Super-admin** | `isSuperAdmin()` | Seul à pouvoir modifier `admins/{adminId}` (rôles, permissions d'un autre admin) |
| **Cloud Functions (Admin SDK)** | Contourne totalement les règles | `audit_logs`, `security_events`, `rate_limits`, `invalid_fcm_tokens`, `dispatch_metrics`, `ai_conversations`, `ai_pending_actions`, `pharmacie_credentials`, `commissions` — toutes en écriture `if false` pour tout client, alimentées exclusivement côté serveur |

## 4. Patterns de sécurité réutilisés (à connaître avant d'ajouter une nouvelle collection)

### a. Le solde ne peut que diminuer côté client
`clients`, `livreurs` : `request.resource.data.wallet < resource.data.wallet`. Un crédit de wallet (recharge, remboursement, gain) ne peut **jamais** venir d'une écriture client directe — uniquement d'une Cloud Function via Admin SDK. C'est le mécanisme central qui empêche un client de s'auto-créditer.

### b. State machine explicite pour les statuts de commande
`orders` : chaque transition de statut autorisée est énumérée explicitement (`pending→assigned`, `assigned→accepted`, etc.), avec les champs qui doivent rester `unchanged()` à chaque étape (`budget`, `clientId`, `isPaid`, `paymentMethod`, `driverId`). Empêche un livreur de, par exemple, passer une commande direct de `pending` à `delivered`, ou de modifier le montant au passage.

### c. "Doit passer par une Cloud Function" — deux variantes
1. **Écriture totalement interdite** (`allow write: if false`) : `pharmacie_credentials`, `ai_conversations`, `ai_pending_actions`, `audit_logs`, `security_events` (write), `rate_limits`, `invalid_fcm_tokens`, `dispatch_metrics`, `real_estate_visit_requests`, `commissions`.
2. **Transition spécifique bloquée mais le reste autorisé** : `ekbine_orders` interdit explicitly le passage à `completed` en écriture directe (commentaire : "passe obligatoirement par ekClientConfirmOrder pour créditer le wallet agent atomiquement") tout en autorisant les autres transitions en direct.

### d. Compteurs publics incrémentables par tous
`marketplace_products.views`/`.favoritesCount`, `real_estate_listings.views`, `places.searchCount` : n'importe quel utilisateur authentifié peut modifier **uniquement ce champ** (`affectedKeys().hasOnly([...])`), jamais le reste du document. Permet des compteurs sans passer par une Cloud Function pour chaque vue.

### e. Champs financiers listés explicitement comme protégés
`boulangeries`, `fleet_owners` : `wallet`, `subscriptionStatus`, `subscriptionExpiresAt`, `vipStatus`, `vipExpiresAt` (et `vipStartedAt` pour boulangeries) — le propriétaire peut éditer son profil librement SAUF ces champs précis, listés un par un plutôt que par une liste blanche des champs autorisés. Fonctionnellement équivalent à une liste blanche mais plus lisible pour ces documents à beaucoup de champs.

## 5. Trouvaille zero-trust concrète : `livreurs` en lecture large (partiellement traitée le 2026-07-01)

`match /livreurs/{livreurId} { allow read: if isAuth(); }` — **tout utilisateur authentifié, y compris anonyme** (l'app connecte tout le monde anonymement par défaut), peut lire l'intégralité de n'importe quel document livreur : position GPS en temps réel, `wallet`, `isOnline`, à tout moment, pas seulement pendant une livraison active qui le concerne. C'est plus large que ce que demande ce prompt ("le client ne peut lire que pendant une livraison active").

**Ce n'est pas un oubli isolé** — 17 fichiers Flutter lisent directement `livreurs` (`client_map.dart` pour afficher les livreurs disponibles avant même la création d'une commande, plusieurs dashboards admin/partenaire, écrans de tracking). Resserrer cette règle à "lecture uniquement pendant une livraison active" casserait la fonctionnalité "voir les livreurs disponibles à proximité" avant commande, qui semble être un vrai besoin produit. Une vraie correction demanderait soit (a) d'accepter ce compromis produit tel quel (documenté, pas un oubli), soit (b) de séparer les champs sensibles (`wallet`) des champs nécessaires à l'affichage public (position, disponibilité) dans une sous-collection à droits différents — changement de structure, pas une simple règle, à trancher explicitement plutôt qu'à corriger silencieusement.

**Mise à jour (2026-07-01) — la justification historique de cette règle large a disparu, mais la règle elle-même n'a pas encore été resserrée :** la lecture cross-user du `wallet` était nécessaire au dispatch, qui tournait côté client (`findNearestDriver()` lisait le `wallet` de tous les livreurs en ligne pour filtrer les candidats). Le dispatch a été migré vers une Cloud Function (`dispatchOrderToDriver`, Admin SDK, ignore les règles) — cette justification n'existe donc plus. En creusant l'option (b) ci-dessus (séparer `wallet` dans une sous-collection restreinte), l'audit a révélé que le champ est encore lu/écrit directement en client sur ~10 sites supplémentaires : les écrans propres au livreur (lecture de son propre solde, légitime), 3 écrans admin, et `fleet_dashboard.dart` (un rôle « patron de flotte », modélisé par `fleet_owners/{id}` dans les règles mais jamais référencé par la règle `livreurs` — nécessiterait un nouvel helper `isFleetOwnerOf()`). Décision explicite (2026-07-01) : ne pas migrer ces ~10 sites maintenant — chantier séparé à prioriser. Le risque résiduel accepté est une exposition de **visibilité de solde**, pas de fonds : la règle `allow update` (owner ne peut que diminuer son propre wallet, sinon `isAdmin()`) reste inchangée et bloque toute écriture cross-user.

En creusant ce chantier, deux trouvailles supplémentaires, non liées à la règle de lecture elle-même :
- **Bug corrigé (2026-07-01)** : `FirestoreService.payOrderFromWallet()` (client crédite le wallet du livreur), le remboursement de commission dans `cancelOrder()`, et la branche de crédit direct de `deliverOrder()` violaient déjà la règle `allow update` actuelle (écriture cross-user non-admin, non-décroissante) — ces trois transactions échouaient donc avec `permission-denied` en production. Corrigé en les portant en Cloud Functions (`payOrderFromWalletCF`/`cancelOrderCF`/`deliverOrderCF`, `functions/orderActions.js`, 18 tests). Voir `CLAUDE.md`, section Livraison.
- **Bug non corrigé, découvert au passage** : `fleet_dashboard.dart` crée un nouveau compte livreur via `createUserWithEmailAndPassword` (connexion automatique en tant que ce nouveau compte), puis tente `livreurs/{driverUid}.set({...})` — mais `allow create: if isAdmin();` n'autorise que les admins. Ce flux semble donc déjà échouer en production. Non corrigé (hors périmètre) — voir `CLAUDE.md`, section Livraison.

## 6. Écart avec la demande du prompt : rôles Support/Modérateur/Comptable et audit_logs super-admin-only

- Le prompt demande un RBAC avec des rôles nommés Support/Modérateur/Comptable distincts des admins classiques — **aucun n'existe** dans le schéma actuel (déjà documenté dans `CLAUDE.md`, section RBAC). Les règles ne peuvent pas contrôler des rôles qui n'existent pas dans les données.
- **Traité (2026-07-01)** : le prompt demande `audit_logs` en lecture **Super Administrateur uniquement** — la règle a été resserrée de `isAdmin()` à `isSuperAdmin()` (confirmé sans régression : le menu "Sécurité" de `admin_dashboard.dart` menant à `AdminSecurityDashboard`, seul lecteur de `audit_logs` côté UI, est déjà conditionné à `if (_isSuper)`).

## 7. Collections mentionnées dans ce prompt qui n'existent pas

`driver_locations` (position = champs sur `livreurs`, pas de collection séparée), `ai_memory`/`ai_feedback`/`ai_preferences` (seuls `ai_conversations`/`ai_pending_actions` existent), `system_settings` (c'est `config`/`app_config`), `roles`/`permissions` comme collections séparées (le RBAC actuel est intégré aux documents `admins`, pas dans des collections dédiées). Aucune de ces collections n'a été créée — voir `FIRESTORE_SCHEMA.md` pour le schéma réel complet.

## 8. Ce qui reste à faire, non fait dans cette passe

- Tests automatisés des règles (voir section suivante — traité séparément dans cette même session).
- `audit_logs` (section 6) : traité (2026-07-01).
- `livreurs` en lecture large (section 5) : la justification historique (dispatch client-side) a disparu (2026-07-01), mais le champ `wallet` lui-même n'a pas été déplacé/restreint — décision explicite de laisser ce chantier pour une session dédiée (~10 sites de lecture/écriture restants + nouvel helper `isFleetOwnerOf()`).
- RBAC nommé (Support/Modérateur/Comptable) — à construire seulement si une fonctionnalité concrète en a besoin (déjà la position actée dans `CLAUDE.md`).
