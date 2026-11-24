# SEC-01 — S6.7 : audit de conception d'un accès sécurisé au téléphone du livreur

Date : 2026-11-21
Type : audit READ-ONLY + étude de conception (aucune implémentation)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md`, `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md`, `docs/SEC01_S6_0_2/S6_0_3`, `docs/SEC01_S6_3_MULTI_DRIVER_READERS_MIGRATION.md`, `docs/SEC01_S6_3_1_VEHICLE_LIVE_MARKER_AUDIT.md`, `docs/SEC01_S6_4_HYBRID_READERS_MIGRATION.md`, `docs/SEC01_S6_5_PHONE_DEPENDENCY_AUDIT.md`, `docs/SEC01_S6_6_PHONE_READERS_MIGRATION.md`

## 1. Résumé exécutif

Cet audit conçoit, sans l'implémenter, une Cloud Function callable dédiée (`getDriverPhoneForOrderCF`, nom proposé) destinée à remplacer progressivement les 7 lectures directes de `livreurs.phone`. L'état du code a été re-vérifié (pas seulement relu dans les rapports précédents) : les 7 lecteurs sont inchangés depuis S6.6, les 4 lecteurs hybrides migrés en S6.6 lisent désormais leur partie publique depuis `driver_public` mais conservent tous une lecture directe de `livreurs.phone` pour le numéro lui-même — exactement la cible de cette conception.

La solution recommandée est une **callable unique avec autorisation contextuelle par rôle**, calquée sur le pattern déjà en production (`orderActions.js`, vérification `order.clientId !== uid`), car c'est la plus proportionnée : une seule fonction, un seul ensemble de tests, une seule politique de rate-limit, une logique d'autorisation centralisée et auditée une fois plutôt que dupliquée dans 4 à 5 fonctions distinctes (client/pharmacie/boulangerie/vendeur/admin). Un risque de conception important est confirmé et précisé : les Rules `orders` actuelles autorisent déjà la lecture complète du document par `clientId`, `driverId`, `sellerId`, le propriétaire pharmacie et l'admin — toute solution basée sur un champ `orders.driverPhone` (Option B de S6.5) hériterait de cette sur-exposition ; la callable proposée ici l'évite structurellement, puisqu'elle ne transite jamais par une lecture Firestore partagée.

## 2. Inventaire exhaustif de `phone` (re-vérifié, pas supposé inchangé)

### 2.1 Lectures de `livreurs.phone`

Recherche exhaustive refaite (`grep -rn "collection('livreurs')\|collection(\"livreurs\")"` croisé avec `phone`) : **toujours exactement 7 sites**, dont 4 désormais des lectures *dédiées* à `phone` seul (suite à la séparation S6.6) et 2 qui l'étaient déjà nativement :

| # | Fichier:méthode | État post-S6.6 | Acteur | Contexte | Finalité | Lien avec la commande | Autorisation actuelle | Risque de confidentialité |
|---|---|---|---|---|---|---|---|---|
| 1 | `lib/web/pages/client/web_client_dashboard.dart::_callDriver` (lignes 906-916) | Lecture `phone` seule (inchangé, jamais mixé) | Client (web) | Tableau de bord client, commande en cours | Appel direct (`tel:`) | `driverId` de la commande affichée | `isAuth()` sur `livreurs` — aucune vérification que l'appelant est bien le `clientId` de cette commande précise au niveau de la Rule (la vérification se fait implicitement par la navigation UI, pas par la donnée) | Moyen — un client authentifié pourrait, par appel direct Firestore hors UI, lire le téléphone d'un livreur qui ne lui est pas assigné |
| 2 | `lib/screens/client/suivi_commande.dart::_callDriver` (lignes 136-154) | Lecture `phone` seule (inchangé) | Client (mobile) | Suivi de commande | Appel direct (`tel:`) | `driverId` de la commande affichée | Idem n°1 | Idem n°1 |
| 3 | `lib/screens/customer_tracking_screen.dart::_loadDriverInfoById` (lignes 310-335, post-S6.6) | Second `get()` dédié à `phone` (depuis S6.6) | Client (mobile, flux `livraison_screen.dart`) | Suivi de livraison active | Affichage + bouton d'appel (`EtaCard`) | `driverId` de la commande | Idem n°1 | Idem n°1 |
| 4 | `lib/screens/admin/admin_map.dart` (lignes 24, 67, 75) | Lecture non filtrée, tous les livreurs | Admin | Carte de supervision | Affichage passif (snippet) | Aucun lien direct avec une commande précise | `isAuth()` sur `livreurs` — mais accès déjà légitime par ailleurs (console admin, `isAdmin()` sur d'autres collections) | Nul — l'admin a déjà un accès complet et légitime |
| 5 | `lib/screens/pharmacie/pharmacie_dashboard.dart::_DriverInfoCard` (lignes 958-991, post-S6.6) | Second `StreamBuilder` imbriqué dédié à `phone`/`motoModel` (depuis S6.6) | Partenaire (pharmacie) | Commande assignée à ce partenaire | Vérification visuelle + appel | `driverId` de la commande du partenaire, via `pharmacieId` | Idem n°1, pour un partenaire plutôt qu'un client | Idem n°1, étendu à « un partenaire authentifié pourrait lire le téléphone d'un livreur non assigné à l'une de ses commandes » |
| 6 | `lib/screens/boulangerie/boulangerie_dashboard.dart` (lignes 705-786, post-S6.6) | Second `StreamBuilder` imbriqué dédié à `phone` (depuis S6.6) | Partenaire (boulangerie) | Commande assignée | Affichage + appel | `driverId` de la commande, via `sellerId`/`sellerType` | Idem n°5 | Idem n°5 |
| 7 | `lib/screens/seller/seller_dashboard.dart::_DriverSection` (lignes 1413-1572, post-S6.6) | Second `StreamBuilder` imbriqué dédié à `phone` (depuis S6.6) | Partenaire (vendeur marketplace) | Commande assignée | Affichage + appel | `driverId` de la commande, via `sellerId` | Idem n°5 | Idem n°5 |

### 2.2 Écritures de `livreurs.phone`

Re-vérifiées (inchangées depuis S6.5) :
- **Actif** : `lib/screens/admin/driver_requests_page.dart::_approve` (copie depuis `driver_requests` à l'approbation admin).
- **Code mort** (zéro appelant, confirmé à nouveau par `grep -rn "DriverService"`/`grep -rn "addDriverToFleet"`) : `lib/services/driver_service.dart::registerDriver`, `lib/services/firestore_service.dart::addDriverToFleet`.
- **Suppression** : `functions/accountDeletion.js` (redaction générique à la suppression de compte).

### 2.3 Usages indirects / Web

Aucun lecteur supplémentaire trouvé côté Web au-delà de `web_client_dashboard.dart` (n°1, déjà listé) — `lib/web/pages/admin/web_admin_dashboard.dart:715` lit un champ `vehicle` (sans rapport, cf. S6.3.1), pas `phone` sur `livreurs`. Aucun accès indirect additionnel (ex. via une Cloud Function cliente) trouvé au-delà de ceux déjà documentés en S6.5/S6.6.

### 2.4 `orders.driverPhone`

Reconfirmé absent en tant que donnée réellement écrite (§5.5 de S6.5) — aucune Cloud Function (`driverAcceptance.js`, `dispatch.js`, `orderActions.js`, `driverTransfer.js`, `dispatchRetry.js`) ne l'écrit, recherche exhaustive refaite, même résultat.

## 3. Architecture actuelle (re-vérifiée)

- **Statuts de commande** (`firestore.rules`, state machine) : `pending → broadcast/assigned → accepted → picked_up → delivered`, ou `cancelled` — confirmé inchangé.
- **Attribution du livreur** : `functions/dispatch.js` (assignation serveur initiale), `functions/dispatchRetry.js` (nouvelle tentative après expiration), `functions/driverTransfer.js` (transfert en cours de route, `order.driverId` réaffecté à un nouveau livreur — confirmé ligne 501, `newDriverId: t.toDriverId`).
- **Rôles et identité des commandes** : `clientId` (toujours), `driverId` (dès assignation), `sellerId`+`sellerType` (marketplace/boutique/restaurant/boulangerie), `pharmacieId` (pharmacie, vérifié via `pharmacies/{id}.currentUid`, fonction `isPharmacieOwnerOfOrder()` dans `firestore.rules:301-306`).
- **Pattern callable déjà en production** (`functions/orderActions.js`, confirmé à plusieurs endroits, ex. lignes 72, 217, 576, 1775) : `onCall(async (request) => { const uid = request.auth?.uid; ...; const order = (await db.collection('orders').doc(orderId).get()).data(); if (order.clientId !== uid) throw new HttpsError('permission-denied', ...); ... })` — c'est le squelette d'autorisation que la callable proposée doit reproduire, pas inventer.
- **Primitives serveur réutilisables** (`functions/index.js`) : `checkRateLimit(uid, action, maxRequests, windowSeconds)` (lignes 279-299, transactionnel, fenêtre glissante) et `logAudit(details)` (lignes 303-318, écrit dans `audit_logs`, Cloud-Function-only) — toutes deux déjà conçues pour ce type de besoin, à réutiliser telles quelles.
- **App Check** : SDK actif côté client, mais `enforceAppCheck` **non activé** côté fonctions (confirmé dans `.claude/rules/firebase-functions.md`) — pas une protection disponible aujourd'hui sans une décision et un rollout séparés.
- **Région** : `europe-west1` (toutes les Cloud Functions existantes, à reproduire).

## 4. Risques

- **Risque principal confirmé** (déjà identifié en S6.5, précisé ici) : `orders` est lisible par `clientId`, `driverId`, `sellerId`, le propriétaire pharmacie, et l'admin (`firestore.rules:767-774`) — toute solution fondée sur un champ de commande partagé exposerait le numéro à plus de rôles que nécessaire. La callable proposée évite ce risque par construction : la réponse n'est jamais stockée dans un document lisible par un tiers, seulement retournée à l'appelant de l'invocation.
- **Risque d'énumération** : un appelant pourrait tenter de deviner des `orderId` pour sonder des numéros — à traiter par validation stricte de l'appartenance de la commande à l'appelant (jamais sur la seule confiance d'un ID fourni, cf. §3.C) et par limitation de débit (§7).
- **Risque de transfert de livreur** : si l'autorisation se fondait sur un `driverId` mis en cache côté client plutôt que relu depuis le document `orders` au moment de l'appel, un client pourrait recevoir le numéro d'un ancien livreur après un transfert — à éviter en relisant toujours `orders.driverId` côté serveur au moment de l'appel (jamais un `driverId` fourni par le client).
- **Risque de fuite via les logs** : journaliser le numéro en clair dans `audit_logs` dupliquerait l'exposition qu'on cherche à réduire — à éviter (§5).
- **Risque de sur-ingénierie** : une callable séparée par rôle (client/pharmacie/boulangerie/vendeur) dupliquerait la même logique de vérification 4 à 5 fois, avec un risque de divergence silencieuse entre les copies (une correction de sécurité appliquée à l'une mais oubliée dans une autre) — risque organisationnel, pas seulement technique.

## 5. Conception de la callable proposée (non implémentée)

### Nom et signature

`getDriverPhoneForOrderCF` (nom proposé, cohérent avec les conventions existantes — `acceptOrderCF`, `cancelOrderCF`, `adminDriverRechargeCF`), région `europe-west1`, enveloppe de réponse standard `{success, error, message, data, code}` (nouvelle fonction, donc pas de rétro-compatibilité à préserver).

Entrée : `{ orderId: string }` uniquement. **Jamais de `driverId` fourni par l'appelant** (toujours relu depuis `orders.driverId`, cf. §5.C) — élimine par construction le risque d'accès croisé entre un `orderId` légitime et un `driverId` arbitraire.

### A. Authentification

- `request.auth` obligatoire — `if (!request.auth?.uid) throw new HttpsError('unauthenticated', ...)`, pattern identique à toutes les callables existantes.
- **Utilisateurs anonymes** : l'authentification anonyme (clients mobile par défaut, `.claude/rules/auth-identity.md`) donne un `uid` Firebase Auth valide — `request.auth.uid` existe donc aussi pour un client anonyme qui a passé une commande. Aucune distinction technique nécessaire à ce niveau ; la vérification métier (§B) s'appuie sur la correspondance `orders.clientId === uid`, qui fonctionne identiquement pour un compte anonyme ou identifié.
- **Rôle de l'appelant** : non déterminé par un claim ou un paramètre fourni par le client, mais par la *relation réelle* entre l'uid authentifié et le document `orders` (§C) — un appelant ne peut pas « se déclarer » client, livreur, admin ou partenaire ; son rôle découle de ce que le document `orders`/`pharmacies`/`admins` dit de lui.

### B. Autorisation métier — conditions exactes par acteur et statut

Voir la matrice complète en §6. Principes directeurs :

- **Client propriétaire de la commande** : autorisé si `order.clientId === uid`, **et** `order.driverId` existe (un livreur est assigné — sinon il n'y a personne à appeler), **et** le statut de la commande n'est ni `cancelled` ni `delivered` depuis plus d'une fenêtre raisonnable (ex. quelques minutes après livraison, pour couvrir un contact de dernière minute légitime — valeur exacte à trancher lors de la conception détaillée, non figée ici).
- **Livreur réellement affecté** : cas d'usage non identifié parmi les 7 lecteurs (aucun écran livreur ne lit le téléphone d'un autre livreur) — **exclu par défaut** de l'autorisation de cette callable, sauf besoin futur explicitement justifié.
- **Admin** : toujours autorisé (`isAdmin()`), cohérent avec son accès déjà légitime et complet à `livreurs` — mais pour cette callable précise, l'admin n'a normalement pas besoin de passer par elle puisqu'il lit déjà `livreurs` directement (`admin_map.dart`) ; mentionné pour complétude de la matrice, pas comme un besoin réel à migrer (cf. §7).
- **Partenaire ayant réellement besoin de contacter le livreur** : autorisé si le partenaire authentifié est le véritable propriétaire de la commande — vérifié différemment selon le type :
  - Pharmacie : `order.pharmacieId` existe et `pharmacies/{order.pharmacieId}.currentUid === uid` (reprend exactement `isPharmacieOwnerOfOrder()` des Rules actuelles, traduit côté serveur).
  - Boulangerie/vendeur marketplace : `order.sellerId === uid` (et éventuellement `order.sellerType` correspond au rôle attendu, pour éviter qu'un vendeur marketplace invoque la callable sur une commande boulangerie par erreur de type — défense en profondeur, pas une faille sans elle).
- **Commande annulée** (`cancelled`) : refusé — plus aucune raison légitime de contacter le livreur après annulation.
- **Commande terminée** (`delivered`) : refusé après une fenêtre de grâce courte (valeur à définir), sinon un ancien client pourrait contacter indéfiniment un livreur pour une commande close depuis longtemps.
- **Commande en attente** (`pending`/`broadcast`) : refusé — `driverId` n'existe pas encore, rien à retourner.
- **Commande acceptée/en cours** (`assigned`/`accepted`/`picked_up`) : autorisé (cas d'usage principal).
- **Commande dont le livreur a été changé** (transfert) : autorisé, à condition que `order.driverId` soit relu au moment de l'appel (jamais mis en cache côté client) — retourne alors le téléphone du **nouveau** livreur, jamais de l'ancien.

**Principe non négociable, conforme à la consigne** : l'autorisation ne repose jamais sur le seul `orderId` fourni — elle exige systématiquement une correspondance vérifiée côté serveur entre l'identité de l'appelant (`request.auth.uid`) et un champ du document `orders` relu depuis Firestore (`clientId`, `sellerId`, ou `pharmacieId` → `pharmacies.currentUid`), jamais sur une affirmation du client.

### C. Validation server-side — séquence proposée

1. Lire `orders/{orderId}` (Admin SDK, hors Rules). Si absent → `not-found`, message générique (§D).
2. Vérifier le statut (§B) — rejeter `pending`/`broadcast`/`cancelled`, et `delivered` hors fenêtre de grâce.
3. Déterminer le rôle de l'appelant par rapport à **ce** document précis (`clientId`, `sellerId`+`sellerType`, ou `pharmacieId`→`pharmacies.currentUid`), ou `isAdmin()` (lecture de `admins/{uid}`). Si aucune correspondance → `permission-denied`.
4. Relire `order.driverId` depuis le document fraîchement lu à l'étape 1 (jamais un paramètre d'entrée) ; si absent → `failed-precondition` (« aucun livreur assigné »).
5. Lire `livreurs/{driverId}` (Admin SDK) ; si absent ou si `phone` absent/vide → `not-found` côté données, pas une erreur d'autorisation.
6. Retourner uniquement `{ phone: livreurDoc.data().phone }`.
7. Journaliser l'accès (§E) — sans le numéro en clair.

Aucune étape ne fait confiance à une donnée fournie par le client au-delà de `orderId` (un simple identifiant, sans valeur sensible en lui-même).

### D. Retour de données — réponse minimale

```
{ success: true, data: { phone: "+225XXXXXXXXXX" }, error: null, message: null, code: null }
```

**Jamais retournés** : `wallet`, tout champ financier, adresse, `identifiant`, `email`, photo, statut de suspension, ou tout autre champ de `livreurs`/`orders` au-delà du strict numéro demandé — la fonction ne doit project­er que ce seul champ depuis `livreurs`, jamais le document entier (différence fondamentale par rapport aux lectures directes actuelles, qui ramènent implicitement tout le document).

## 6. Matrice d'autorisation par acteur et statut de commande

| Acteur | `pending`/`broadcast` | `assigned`/`accepted`/`picked_up` | `delivered` (fenêtre de grâce) | `delivered` (hors fenêtre) | `cancelled` |
|---|---|---|---|---|---|
| Client (`clientId === uid`) | Refusé (pas de `driverId`) | **Autorisé** | Autorisé (court délai) | Refusé | Refusé |
| Pharmacie (`pharmacieId` → `currentUid`) | Refusé | **Autorisé** | Autorisé (court délai) | Refusé | Refusé |
| Boulangerie/vendeur (`sellerId === uid`) | Refusé | **Autorisé** | Autorisé (court délai) | Refusé | Refusé |
| Admin (`isAdmin()`) | Autorisé (si besoin, cas rare) | Autorisé | Autorisé | Autorisé | Autorisé (traçabilité/litige) |
| Livreur (tout autre que le sien) | Refusé | Refusé | Refusé | Refusé | Refusé |
| Tiers non lié à la commande | Refusé | Refusé | Refusé | Refusé | Refusé |

La durée exacte de la « fenêtre de grâce » post-livraison n'est pas fixée ici (décision produit, pas une question de sécurité pure) — proposée à titre d'exemple, quelques minutes à quelques heures, jamais indéfinie.

## 7. Analyse anti-abus

- **Limitation des appels** : `checkRateLimit(uid, 'getDriverPhoneForOrder', max, windowSeconds)` — réutilisation directe de la primitive existante (`functions/index.js:279-299`), sans nouvelle dépendance. Valeurs proposées à titre d'exemple (à affiner en conception détaillée) : quelques appels par minute et par utilisateur, suffisant pour un usage légitime (consulter le numéro une poignée de fois pendant une livraison) mais insuffisant pour une énumération.
- **Limitation par commande** : une seconde clé de limitation possible, par `orderId` plutôt que par `uid` seul (ex. `rate_limits` doc `${orderId}_phone_access`), pour contenir un abus même si plusieurs comptes ciblaient la même commande (cas peu probable compte tenu de l'autorisation stricte du §B, mais defense-in-depth peu coûteuse).
- **Protection contre l'énumération des IDs** : déjà structurellement couverte par l'autorisation du §C (un `orderId` qui n'appartient pas à l'appelant est toujours rejeté, qu'il existe ou non) — combinée à un message d'erreur **identique** pour « commande inexistante » et « commande non autorisée » (évite qu'un attaquant distingue les deux cas en sondant des ID au hasard).
- **Gestion des erreurs sans révélation excessive** : tous les rejets d'autorisation renvoient le même code (`permission-denied`) et le même message générique, sans préciser si c'est l'`orderId`, le statut, ou le rôle qui a échoué — cohérent avec le principe déjà appliqué dans `orderActions.js` pour d'autres callables sensibles.
- **App Check** : non activé aujourd'hui côté fonctions (§3) — pourrait être évalué pour cette fonction précise lors d'un rollout plus large, mais ne doit pas être une dépendance bloquante de cette conception (décision séparée, hors périmètre).
- **Aucune nouvelle dépendance** : toutes les primitives mobilisées (`checkRateLimit`, `logAudit`, `HttpsError`, `onCall`) existent déjà dans `functions/index.js`.

## 8. Analyse de journalisation

- **Champs à journaliser** (via `logAudit`, réutilisation directe) : `userId` (appelant), `userType` (rôle déterminé au §C, pas déclaré par le client), `action: 'getDriverPhoneForOrder'`, `targetId: orderId`, `metadata: { driverId, authorized: true/false, reason }` (`reason` = catégorie du résultat, ex. `'client_active_order'`/`'pharmacie_owner'`/`'denied_wrong_status'`, jamais une donnée personnelle).
- **Risque de stockage du numéro dans les logs** : réel si implémenté naïvement (ex. un `console.log` de débogage incluant la réponse complète) — à proscrire explicitement dans la conception détaillée. `audit_logs` ne doit recevoir ni `phone` ni aucune donnée dérivée permettant de le reconstituer (pas même un hash réversible ou les derniers chiffres).
- **Accès refusés** : à journaliser également (`status: 'denied'`), utile pour détecter un pattern d'énumération (plusieurs refus consécutifs du même `uid` sur des `orderId` différents) — sans stocker le numéro bien sûr, puisqu'un refus ne le lit jamais.
- **Date serveur** : `admin.firestore.FieldValue.serverTimestamp()`, comme toute écriture `audit_logs` existante — jamais une date fournie par le client.

## 9. Analyse des Rules Firestore (incohérence déjà relevée, non modifiée)

- **Lecture actuelle de `livreurs`** (`firestore.rules:396-500`) : `allow read: if isAuth();` — confirmé inchangé. Tout utilisateur authentifié, anonymes compris (authentification anonyme Firebase, pas un visiteur non authentifié), peut lire l'intégralité du document, `phone`/`wallet`/`identifiant` inclus.
- **Utilisateurs anonymes** : `isAuth()` les inclut (ce sont des utilisateurs Firebase Auth à part entière, simplement sans email/mot de passe) — ce n'est pas un accès non authentifié au sens strict, mais c'est un seuil d'authentification très bas pour une donnée aussi sensible que `phone`.
- **Utilisateurs non authentifiés** : aucun accès (`isAuth()` l'exclut) — confirmé, pas de régression à signaler ici.
- **Restrictions actuelles sur `phone` lui-même** : aucune — ni en lecture (toute la collection partage la même règle `isAuth()`), ni en écriture (confirmé en S6.5 : la branche propriétaire de la règle `update` ne contraint pas `phone` par `unchanged()`, contrairement à `wallet`/`isSuspended`/`ownerId`/`ownerName`).
- **Risque de la lecture de documents entiers** : structurel à Firestore Rules — il n'existe pas de restriction par champ à l'intérieur d'une règle de lecture de document (`allow read` s'applique à tout le document ou à rien). C'est précisément pourquoi `driver_public` a été créé comme **collection séparée** plutôt que comme une tentative de filtrer `livreurs` par champ — et c'est aussi pourquoi la callable proposée ici est la bonne réponse pour `phone` : elle ne nécessite pas de rendre `livreurs` plus restrictif par champ (impossible), seulement de ne plus y lire directement depuis le client pour ce besoin précis.
- **Possibilités de restriction future** : fermer `livreurs` à `isOwner()`/`isAdmin()` uniquement (retirer `isAuth()` générique) reste l'objectif final de SEC-01, mais seulement une fois **tous** les lecteurs légitimes basculés vers une alternative (`driver_public` pour les champs publics, cette callable pour `phone`) — non fait ici, et la checklist de fermeture (`docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` §12) reste la référence à cocher avant toute fermeture.
- **Aucune Rule modifiée, aucun déploiement proposé** dans cette phase, conformément à la consigne.

## 10. Plan de migration des 7 lecteurs (établi, non exécuté)

Aucun des 7 fichiers n'a été modifié dans cette phase.

| Ordre | Lecteur | Risque | Préconditions | Compatibilité | Tests requis | Risque de régression | Dépendances |
|---|---|---|---|---|---|---|---|
| 1 | `customer_tracking_screen.dart::_loadDriverInfoById` | Faible — déjà un `get()` isolé pour `phone` depuis S6.6, remplacer l'appel Firestore par un appel `httpsCallable` est un changement localisé | Callable déployée et testée | Élevée — un seul point d'appel | Test de la callable (autorisation client), test de non-régression de l'écran (numéro toujours affiché pour une commande active) | Faible | Callable implémentée |
| 2 | `web_client_dashboard.dart::_callDriver` | Faible — même raisonnement, `get()` isolé | Idem | Élevée | Idem | Faible | Idem |
| 3 | `suivi_commande.dart::_callDriver` | Faible — idem | Idem | Élevée | Idem | Faible | Idem |
| 4 | `boulangerie_dashboard.dart` | Faible à modéré — second `StreamBuilder` (S6.6) à remplacer par un appel ponctuel (`httpsCallable` ne fournit pas de flux temps réel nativement ; nécessiterait soit un appel différé/`FutureBuilder`, soit un appel déclenché à la demande plutôt qu'en continu) | Callable + décision sur le modèle d'appel (continu vs à la demande) | Modérée — changement de modèle (stream → future), pas seulement de source | Test de l'écran avec un appel différé, vérification qu'un changement de livreur en cours de commande redéclenche l'appel | Modéré — le numéro ne serait plus mis à jour en temps réel sans redéclenchement explicite | Callable + décision de conception sur le déclenchement |
| 5 | `seller_dashboard.dart::_DriverSection` | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 |
| 6 | `pharmacie_dashboard.dart::_DriverInfoCard` | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 | Idem n°4 |
| 7 | `admin_map.dart` | **Ne pas migrer** — accès admin déjà légitime et complet (position constante depuis S6.0 §6), migrer n'apporterait aucun bénéfice de sécurité et ajouterait une complexité (callable à appeler pour chaque livreur affiché sur la carte, potentiellement des dizaines) | N/A | N/A | N/A | N/A | N/A |

**Justification de l'ordre** : les 3 lecteurs `get()` ponctuels (n°1-3) sont migrés en premier car le remplacement est un changement de source sans changement de modèle (toujours un appel unique à la demande). Les 3 lecteurs en `StreamBuilder` (n°4-6) sont migrés ensuite car ils exigent une décision de conception supplémentaire (remplacer un flux temps réel par un mécanisme d'appel à la demande, ou accepter un rafraîchissement moins immédiat) — un risque de régression plus élevé que les premiers, donc traité après avoir validé la callable elle-même sur les cas les plus simples. `admin_map.dart` n'est jamais migré.

## 11. Plan de transition (proposé, aucune étape exécutée)

1. **Conception détaillée** (décision produit) : valeurs exactes de rate-limit, durée de la fenêtre de grâce post-livraison, inclusion ou non du cas « admin » dans la callable (ou maintien de son accès direct existant).
2. **Implémentation de la callable** : `getDriverPhoneForOrderCF` dans `functions/`, suivant le squelette du §5.
3. **Tests unitaires** : logique pure de détermination du rôle et de validation de statut (pattern déjà utilisé pour les autres callables de `orderActions.js`, testable via `.run(request)` sans émulateur selon `.claude/rules/firebase-functions.md`).
4. **Tests d'autorisation** : chaque ligne de la matrice (§6), y compris les cas de rejet (mauvais rôle, mauvais statut, commande d'un tiers, `orderId` inexistant).
5. **Tests de régression** : suite `functions/test/orderActions.test.js` et suites associées, pour confirmer qu'aucune fonction existante n'est affectée.
6. **Migration des lecteurs** : dans l'ordre du §10, un par un, chacun avec ses propres tests Flutter ciblés (adaptés au modèle `httpsCallable`).
7. **Vérification des Rules** : aucune modification nécessaire pour la callable elle-même (elle utilise l'Admin SDK, hors Rules) — seulement une revérification qu'aucune Rule n'a besoin d'ajustement pendant la transition (répondre `permission-denied` du côté callable, pas des Rules).
8. **Phase de validation** : période d'observation en conditions réelles (taux de succès/échec de la callable, absence de régression signalée par les 7 écrans) avant d'envisager l'étape suivante.
9. **Fermeture éventuelle de l'accès direct à `phone`** : seulement après que les 6 lecteurs migrables (hors admin) n'utilisent plus `livreurs.phone` directement et après une période d'observation sans repli — à ce stade, une décision séparée pourrait restreindre la lecture de `phone` sur `livreurs` (ex. via un champ non lisible côté Rules, ou en acceptant que l'admin reste le seul lecteur direct légitime). Cette dernière étape reste hypothétique et n'est pas conçue en détail ici (dépend de décisions produit non prises).

Aucune de ces étapes n'a été exécutée dans cette phase.

## 12. Tests futurs recommandés

- Tests unitaires de la logique de détermination du rôle (`clientId`/`sellerId`/`pharmacieId`/admin) sur des documents `orders` simulés (faux Firestore, pattern déjà utilisé par les tests `orderActions.js`).
- Tests couvrant explicitement chaque ligne de la matrice d'autorisation (§6), y compris les statuts refusés.
- Test de non-régression confirmant qu'un changement de `driverId` (transfert) fait retourner le nouveau numéro, jamais l'ancien.
- Test confirmant qu'aucun champ au-delà de `phone` n'est jamais retourné.
- Test confirmant que `audit_logs` ne contient jamais le numéro en clair ni une donnée dérivée.
- Test de la limitation de débit (dépassement du quota → `resource-exhausted`).
- Tests Flutter ciblés par écran migré, adaptés au modèle d'appel retenu (`Future`/`httpsCallable` ponctuel pour n°1-3, mécanisme à définir pour n°4-6).

## 13. Inconnues et réserves

- **Durée exacte de la fenêtre de grâce post-livraison** : décision produit non prise ici, volontairement laissée ouverte (§6).
- **Modèle d'appel pour les lecteurs en `StreamBuilder`** (n°4-6, pharmacie/boulangerie/vendeur) : `httpsCallable` ne fournit pas nativement un flux temps réel — la conception détaillée devra trancher entre un appel déclenché à l'ouverture de l'écran (suffisant si le numéro ne change que rarement en cours de commande), un bouton « afficher le numéro » à la demande (réduit encore les appels, meilleur anti-abus), ou un mécanisme de rafraîchissement périodique — non tranché ici.
- **Cas admin** : mentionné dans la matrice par complétude, mais son inclusion réelle dans la callable (plutôt que son accès direct déjà existant) est une décision de conception, pas une nécessité de sécurité — à trancher séparément.
- **Rôle livreur** : exclu par défaut (§5.B), faute de cas d'usage identifié — à revoir seulement si un besoin futur apparaît explicitement.
- **Chiffrage précis du coût d'implémentation** : qualitatif ici (cohérent avec l'estimation déjà donnée en S6.5 §7-C), un chiffrage détaillé nécessiterait une phase de conception technique dédiée, non faite ici.
- **Impact de `dispatchRetry.js` sur la fenêtre d'autorisation** : confirmé que `driverId` peut être réattribué après expiration, mais le détail précis de ce fichier n'a pas été relu intégralement dans cette phase (cité, pas audité ligne à ligne) — à vérifier lors de la conception détaillée si des cas limites around re-attribution restent incertains.

## 14. Confirmation du respect du périmètre READ-ONLY

Aucun fichier de code, de test, de Rules, de Cloud Function, de configuration, de dépendance ou de lockfile n'a été modifié, créé ou supprimé dans cette phase. Aucun des 7 fichiers lecteurs n'a été touché. Seul le présent rapport Markdown a été créé, dans `docs/`. Aucune callable n'a été implémentée. Aucune connexion à un Firebase réel. Aucun déploiement proposé ni exécuté. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié. Aucune opération Git destructive, aucun commit, aucun push, aucun changement de branche. Toutes les modifications locales préexistantes sont restées intactes.

## 15. Verdict

**AUDIT VALIDÉ**

L'audit répond intégralement aux questions posées : l'inventaire des 7 lecteurs est re-vérifié dans l'état actuel du code (post-S6.6, pas supposé inchangé), la conception de la callable couvre authentification, autorisation métier précise par acteur et statut, validation server-side stricte (jamais sur la seule confiance d'un `orderId`), retour minimal de données, limitation d'abus sans nouvelle dépendance, et journalisation sans exposition du numéro. Le risque de conception déjà identifié en S6.5 (sur-exposition via les Rules `orders` partagées) est repris et confirmé comme argument central en faveur de la callable plutôt que d'un champ `orders.driverPhone`. Un plan de migration des 7 lecteurs et un plan de transition en étapes séparées sont fournis, sans qu'aucune étape ne soit exécutée, conformément au périmètre strictement READ-ONLY de cette mission.

STOP après ce rapport. Aucune implémentation sans autorisation explicite.
