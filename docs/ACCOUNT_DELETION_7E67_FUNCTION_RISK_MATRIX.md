# Mission 7E-67 — Matrice de risque des 74 fonctions sans garde de quarantaine

Date : 2026-11-06 · Projet : `az-express-b0469` · Mode : **lecture seule** (aucun déploiement, aucune écriture distante, aucun commit, aucune activation). Complète `docs/ACCOUNT_DELETION_7E66_PRODUCTION_SAFETY_REPORT.md`.

Légende : **[V]** vérifié dans le code · **[H]** hypothèse · **NON CONFIRMÉ** non vérifiable ici. Gravité : CRITIQUE / ÉLEVÉ / MOYEN / FAIBLE / NON CONFIRMÉ.

## 1. Méthode et résultat en bref

- **[V]** Le code déployé est récupérable : un zip source par fonction Gen2 (`gs://gcf-v2-sources-697217052961-europe-west1/<fn>/function-source.zip`, lecture seule). Les 74 fonctions sont dans deux instantanés complets : **g0** (6 oct., 71 fonctions) et **g8** (17-18 oct., 3 fonctions : `aiConfirmAction`, `diagnoseDriverOccupancy`, `syncDriverOrderLifecycle`). Chaque instantané contient tout le dépôt `functions/`.
- **[V]** Aucune des 74 n'appelle `assertAccountEnabled`, `assertNewAccountActivity` ni ne lit `account_tombstones` (recherche textuelle dans `index.js` et dans les modules appelés ; ces symboles n'existent pas dans g0/g8).
- **Analyse** : extraction statique automatisée (point d'entrée `exports.<nom>`, modules `require`, collections `collection('…')`, transactions, appels Auth/FCM/externes), puis **lecture manuelle** du code des fonctions financières, AZ IA, E-Kbine et comptes. Les colonnes « Lectures/Écritures » sont donc une **liste de collections touchées (lecture ou écriture confondues) par heuristique**, pas une trace d'exécution ; elle peut omettre des chemins dynamiques (`collectionFor(userType)`, `db.collection(variable)`).
- **Comparaison déployé / local [V]** : `feexpayPayments`, `feexpayPayoutScheduler`, `feexpayVerification`, `realestate`, `artisanAccounts`, `authEvents`, `realEstateLocation`, `vehicleModeration`, `walletReconciliation`, `aiToolExecutions`, `azia/tools/wallet` sont **identiques** au local ; **différents** : `index.js`, `ekbineFlow`, `eventReservations`, `professionalSubscriptions`, `marketplacePublishing`, `adminPartnerAccounts`, `passwordReset`, `adminGuards`, `eventNotifications`, `azia/index`, `azia/tools/{delivery,marketplace,ekbine}` (et `azia/pendingActions` vs g8). Le diff détaillé de ces fichiers n'a pas été revu ligne à ligne : **toute redéployer = embarquer ces différences**.
- **Répartition des 74** : 33 callables, 10 HTTP/planifiées, 31 triggers Firestore.
- **Résultat** : **16 fonctions à protéger avant activation (Liste 1)**, 14 fortement recommandées (Liste 2), 44 sans protection nécessaire ou à ne surtout pas bloquer (Liste 3).

## 2. Mécanismes de protection déjà présents (prod) et leurs limites

| Mécanisme | Effet sur un compte en quarantaine | Limite |
|---|---|---|
| Règles Firestore/Storage `isAuth()` + `account_tombstones` (déployées le 28/10) **[V]** | Bloque toute écriture/lecture SDK client protégée (création de commande, profil, wallet par règles) | Ne lie pas l'Admin SDK : aucune des 74 fonctions n'est concernée |
| Moteur de suppression (local, **non déployé**) : `inspect()` avant quarantaine **et à nouveau après les 15 min** (`accountDeletion.js` l.79) **[V]** | Un wallet ≠ 0, une `wallet_transactions`/`withdrawal_requests`/commande non terminale ou `paymentStatus:'pending'` bloque le dossier (`blocked`, compte reste sous tombstone) | Ne couvre pas ce qui est initié **après** la 2ᵉ inspection (quelques secondes avant `deleteUser`) ni **après** la suppression Auth |
| Jeton ID Firebase **[V — comportement documenté]** | Valide ≈ 1 h après `deleteUser`/`revokeRefreshTokens` | Aucun `checkRevoked` ni `verifyIdToken` dans les callables déployés (grep) : un callable sans garde accepte l'ancien jeton |

Conséquence : **les opérations en cours avant la quarantaine sont bloquées en amont (dossier `blocked`), les nouvelles opérations lancées pendant ou après la quarantaine avec un jeton encore valide ne sont arrêtées que par une garde dans la fonction.** Le plus grave n'est pas la perte d'argent de l'utilisateur lui-même (il se recharge de son propre téléphone) mais : (a) des fonds crédités sur un profil anonymisé, (b) des commandes réelles créées par AZ IA pour un compte supprimé, (c) des écritures d'agent/livreur/partenaire qui ressuscitent des données personnelles.

## 3. Analyses de détail des fonctions critiques (preuves de code)

### 3.1 Paiements et portefeuilles

- **`initiateFeexPayPayment`** (déployé : `index.js` l.251-415 ; local l.373) **[V]** : vérifie seulement `request.auth`, `userType` ∈ liste, montant, `checkRateLimit`. Aucune lecture du profil : crée `wallet_transactions` `status:'pending'` (`credited:false`) puis appelle FeexPay (`axios.post …/request/inline`) avec le téléphone fourni. → **peut être initié après quarantaine**. Un collect créé avant quarantaine est détecté par `inspect()` (`paymentStatus`/statut non terminal), un collect créé après la 2ᵉ inspection ne l'est pas.
- **`feexPayWebhook`** (`index.js` l.420 ; module `feexpayPayments.processFeexPayWebhookEvent` l.493-640) **[V]** : appelé par FeexPay sans `request.auth`. Pour une transaction `pending` et un statut de succès confirmé par vérification serveur indépendante (`verifier.confirmPayment`), il exécute une transaction : lit `collectionFor(userType)/{userId}`, **échoue si le profil n'existe pas** (`Utilisateur … introuvable`), sinon `wallet = wallet + amount`, `credited:true`, historique `wallet_transactions` du profil. Un profil **anonymisé mais conservé** (le moteur garde les champs financiers) reste crédité : fonds bloqués sur un compte supprimé. Les webhooks ne doivent **pas** être bloqués par la quarantaine du compte : l'argent a été prélevé chez l'opérateur ; refuser le crédit sans file de remboursement laisserait un paiement non réconcilié (`status:'pending'` + `needsReview`). → Décision D1.
- **`initiateWithdrawal`** (`index.js` l.476-668 ; local l.608) **[V]** : `userType` fourni par l'appelant (validé contre une liste), transaction : lit le profil `collectionFor(userType)/{uid}` (`not-found` s'il n'existe pas), exige `wallet ≥ amount ≥ 500`, débite, crée `withdrawal_requests` (`processing`) et lance le payout FeexPay vers un téléphone fourni par l'appelant. Aucun test `isSuspended`/`isDeleted`/tombstone. Avec un solde nul (condition d'éligibilité à la suppression) le retrait est impossible ; il redevient possible si un crédit tardif (webhook ci-dessus) arrive avant l'invalidation du jeton.
- **`checkWithdrawalStatus` / `checkPendingWithdrawals`** **[V]** : vérifient puis réconcilient des retraits **déjà engagés** (FeexPay `verifyAndApplyWithdrawal`, compensation si échec). Doivent continuer pour un compte en quarantaine ; une compensation crédite le wallet (même remarque que le webhook). La garde globale `onCall` du local bloquerait l'appel utilisateur de `checkWithdrawalStatus` ; c'est sans conséquence financière car le scheduler poursuit la réconciliation (**NON CONFIRMÉ** : lien exact entre l'écran de suivi et ce callable, non revu côté Flutter).
- **`createEventReservationCF`** (`eventReservations.js` l.158-191) **[V]** : débite `clients.wallet` (transaction) et crée une réservation.
- **`manageProfessionalSubscription`** (`professionalSubscriptions.js`) **[V]** : débite le wallet de plusieurs collections (`ekbine_agents.walletBalance`, etc.) et peut appeler `auth.updateUser`.
- **E-Kbine** : `ekClientConfirmOrder` (`index.js` l.1814-1866) **[V]** : le client est l'appelant ; si l'ordre est `proof_sent`, crédite `ekbine_agents.walletBalance`. L'inspection bloque une suppression pour toute commande E-Kbine non terminale du client : le risque n'existe que pour une course née entre les deux inspections. `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `ekbineUpdateDepositAccounts` : transactions sur `ekbine_orders`/`ekbine_agents`, appelant = agent. **Création de commande E-Kbine** : `ekCreateOrderCF` **n'existe pas en production** ; la création reste client → Firestore (règles `isAuth()` donc bloquée).

### 3.2 AZ IA

- **`aiConfirmAction`** (g8, `azia/pendingActions.js` `buildConfirmAction` l.38-130) **[V]** : lit `ai_pending_actions/{actionId}` ; vérifie seulement `data.uid === request.auth.uid`, `status:'pending'` et l'expiration (`expiresAt`) ; exécute `tool.confirmHandler(tx, uid, toolInput)` dans la transaction puis `afterConfirm`. Aucune vérification de compte. Les outils confirmables sont : `initiate_wallet_recharge` (afterConfirm → FeexPay), `create_delivery_order`, `create_shopping_order`, `cancel_order`, `create_ekbine_order` (débit wallet), `create_marketplace_order` (crédit `sellers.wallet` par `FieldValue.increment`), `create_restaurant_order`, `create_pharmacie_order`, `request_property_visit`. → Une action préparée **avant** la quarantaine peut être confirmée **pendant** la quarantaine, **et après la suppression Auth tant que le jeton vit** (les actions `pending` ne sont effacées par `eraseAiData` qu'à la toute fin ; la fenêtre dure donc au minimum de la 2ᵉ inspection à l'effacement). → **commande réelle (livraison espèces) ou recharge créée pour un compte supprimé.**
- **`azIaChat`** : crée de nouvelles actions en attente, `ai_user_memory`, `ai_reminders`, `ai_conversations` ; peut recréer des données personnelles effacées. Aucune garde de compte.
- **`clearAiHistory`**, **`aiSendDueReminders`** (planifiée : lit `ai_reminders` + `clients`, envoie FCM), **`aiCleanupExpiredPendingActions`** (planifiée : expire des actions).

### 3.3 Comptes et authentification

- `resetAccountPassword` (`passwordReset.js` l.97 : `auth.updateUser(accountDoc.id,{password})`), `manageAdminPartnerAccount` (`adminPartnerAccounts.js` l.192 : `auth.updateUser(targetUid,{password})`), `setPharmaciePassword`, `setArtisanPin`, `artisanLogin`, `pharmacieLogin` (lecture/écriture `pharmacie_credentials`, `artisan_credentials`, `service_providers`), `createSubAdmin` (`auth.createUser`), `deleteSubAdmin` (`auth.deleteUser`). Aucun `createCustomToken` ni `setCustomUserClaims` dans le code déployé (grep **[V]**). Une réinitialisation de mot de passe d'un compte désactivé ne le réactive pas (`disabled` n'est pas modifié), mais écrit des secrets pour un compte en suppression.
- Les écritures de **profil** (nom, téléphone, rôle) passent par les règles Firestore (client) : bloquées par `isAuth()`. Aucune des 74 fonctions ne modifie directement `clients.phone`/rôle.

### 3.4 Commandes et livraison

- Création/modification/annulation/acceptation/livraison de commandes : callables **déjà gardés** (g1/g2/g5) ou écritures client bloquées par les règles. Dans les 74 : seuls les chemins **AZ IA** (3.2) créent/annulent des commandes. `syncDriverOrderLifecycle` (g8) réagit à `orders/{id}` (statut `cancelled`/`delivered`/`accepted`), écrit `isOnDelivery`/`pendingOrderId` du livreur et **doit continuer** pour clore proprement les missions. `diagnoseDriverOccupancy` : super-admin, aucun écrit.
- Les 31 triggers (`notify*`, `updateEventProviderRating`, `syncDriverOrderLifecycle`) : lisent des profils (token FCM) et envoient des notifications ; ne modifient aucune commande ni solde **[V pour les fonctions lues ; H pour `eventNotifications`/`vehicleChatNotifications` — lecture partielle]**.

### 3.5 Autres domaines

- **Immobilier** (`realestate.js`, identique au local) : `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest` (admin), `requestPropertyVisit`, `respondToVisitRequest`, `upsertRealEstateLocation` (`realEstateLocation.js`) : écrivent `real_estate_*` avec `request.auth.uid` (données personnelles). Pas de wallet.
- **Marketplace** : `republishMarketplaceProduct`, planifiée `expireMarketplaceProducts` (`marketplace_products`, `sellers`).
- **Auto & Moto** : `moderateVehicleEntity` (admin ; suspensions vendeurs), `notifyVehicleChatRecipient`.
- **Pharmacies** : `pharmacieLogin`, `setPharmaciePassword`, planifiée `syncPharmacyGuards` (**NON CONFIRMÉ** : `pharmacyGuards.js` lu seulement par balayage).
- **Fichiers Storage** : aucune de ces 74 fonctions n'écrit dans Storage (aucun `bucket(` dans les slices) **[V]**. Les fichiers personnels sont effacés par le moteur de suppression (non déployé).

## 4. Matrice de risque (une ligne par fonction)

« Garde actuelle » = vérification de quarantaine exécutée avant l'opération sensible dans le code **déployé** : **non pour les 74 [V]**. « Lectures/Écritures » : collections touchées détectées (heuristique), `*`-marquées incluses via modules. Le détail lecture/écriture exact des triggers `notify*` est volontairement agrégé (lecture de profils pour FCM).

| Fonction | Domaine | Type · instantané · date | Garde actuelle | Collections touchées | Risque après quarantaine | Liste · correction requise |
|---|---|---|---|---|---|---|
| aiCleanupExpiredPendingActions | AZ IA | HTTP/planifiée · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune ; expire des actions, compatible avec l’effacement |
| aiConfirmAction | AZ IA | callable · g8 · 2026-10-17 | non | — | CRITIQUE | L1 — Garde en tête + relecture tombstone dans la transaction de confirmation (azia/pendingActions.js buildConfirmAction) |
| aiSendDueReminders | AZ IA | HTTP/planifiée · g0 · 2026-10-06 | non | real_estate_listings, real_estate_visit_requests, real_estate_agent_requests, real_estate_agents, real_estate_location_access, clients | MOYEN | L2 — Ignorer les rappels dont le uid a un tombstone/isDeleted (envoi FCM + lecture clients) |
| approveRealEstateAgentRequest | Immobilier (admin) | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde sur l’agent cible |
| artisanLogin | Compte/Auth | callable · g0 · 2026-10-06 | non | service_providers, artisan_credentials | ÉLEVÉ | L1 — Garde en tête (aucun createCustomToken trouvé dans le code déployé) |
| azIaChat | AZ IA | callable · g0 · 2026-10-06 | non | — | ÉLEVÉ | L1 — Garde en tête (empêche actions en attente, mémoire, rappels, historique recréés après effacement) |
| checkClientPhone | Compte | callable · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Lecture clients ; aucune |
| checkPendingWithdrawals | Paiement | HTTP/planifiée · g0 · 2026-10-06 | non | request_logs, ai_conversations, ai_pending_actions, withdrawal_requests | ÉLEVÉ | L3 — Aucune garde (réconciliation d’opérations antérieures) ; journaliser tout crédit/compensation sur profil isDeleted |
| checkWithdrawalStatus | Paiement | callable · g0 · 2026-10-06 | non | withdrawal_requests, admins, invalid_fcm_tokens | ÉLEVÉ | L2 — Ne pas bloquer la réconciliation (le scheduler checkPendingWithdrawals continue) ; journaliser toute compensation sur profil supprimé |
| cleanupExpiredRateLimits | Maintenance | HTTP/planifiée · g0 · 2026-10-06 | non | rate_limits, wallet_reconciliation_findings | FAIBLE | L3 — Aucune |
| clearAiHistory | AZ IA | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde en tête (recrée sinon ai_conversations/{uid}) |
| createEventReservationCF | Événements | callable · g0 · 2026-10-06 | non | event_reservation_attempts, event_reservations, clients, event_offers, event_providers, wallet_transactions | ÉLEVÉ | L1 — Garde en tête + tombstone dans la transaction (débit wallet client) |
| createSubAdmin | Admin | callable · g0 · 2026-10-06 | non | admins | MOYEN | L2 — Garde en tête (appelant admin) ; décision D3 sur la suppression d’un admin |
| deleteSubAdmin | Admin | callable · g0 · 2026-10-06 | non | admins | MOYEN | L2 — Garde sur le compte CIBLE |
| diagnoseDriverOccupancy | Livraison (admin) | callable · g8 · 2026-10-17 | non | admins, livreurs, orders | FAIBLE | L3 — Diagnostic sans écriture (code : « No Firestore writes ») |
| ekClientConfirmOrder | E-Kbine | callable · g0 · 2026-10-06 | non | ekbine_orders, ekbine_agents, audit_logs | ÉLEVÉ | L1 — Garde en tête + tombstone dans la transaction (crédite walletBalance de l’agent) |
| ekbineAcceptOrder | E-Kbine | callable · g0 · 2026-10-06 | non | ekbine_orders, ekbine_agents | ÉLEVÉ | L1 — Garde en tête + tombstone de l’agent dans la transaction |
| ekbineAgentDepositAction | E-Kbine | callable · g0 · 2026-10-06 | non | ekbine_orders, ekbine_agents | ÉLEVÉ | L1 — Garde en tête + tombstone de l’agent |
| ekbineSubmitDepositProof | E-Kbine | callable · g0 · 2026-10-06 | non | ekbine_orders | ÉLEVÉ | L1 — Garde en tête |
| ekbineUpdateDepositAccounts | E-Kbine | callable · g0 · 2026-10-06 | non | ekbine_agents | MOYEN | L2 — Garde en tête |
| expireMarketplaceProducts | Marketplace | HTTP/planifiée · g0 · 2026-10-06 | non | marketplace_products, sellers | FAIBLE | L3 — Aucune (planifiée) |
| fcmTokenCleanupCheck | Notifications | HTTP/planifiée · g0 · 2026-10-06 | non | livreurs, invalid_fcm_tokens | FAIBLE | L3 — Aucune |
| feexPayWebhook | Paiement | HTTP/planifiée · g0 · 2026-10-06 | non | withdrawal_requests, wallet_transactions | ÉLEVÉ | L3 — NE PAS bloquer. Décision D1 : créditer + marquer creditedAfterDeletion + security_event, ou refuser et mettre en file de remboursement |
| initiateFeexPayPayment | Paiement | callable · g0 · 2026-10-06 | non | wallet_transactions, withdrawal_requests | CRITIQUE | L1 — Garde en tête + relecture tombstone dans une transaction avant la création du wallet_transactions pending (refuser toute nouvelle recharge) |
| initiateWithdrawal | Paiement | callable · g0 · 2026-10-06 | non | withdrawal_requests, wallet_transactions | CRITIQUE | L1 — Garde en tête + relecture tombstone/isDeleted dans la transaction existante (profil déjà lu) avant débit |
| listAiToolExecutions | AZ IA | callable · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Lecture (admin) — aucune |
| logAdminAuditEvent | Admin | callable · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Journal admin ; ne pas bloquer |
| logAuthEvent | Compte | callable · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Journal d’événements ; ne pas bloquer |
| manageAdminPartnerAccount | Compte/Auth (admin) | callable · g0 · 2026-10-06 | non | admins | ÉLEVÉ | L1 — Garde sur le COMPTE CIBLE (targetUid) : auth.updateUser(targetUid,{password}) |
| manageProfessionalSubscription | Compte/Wallet | callable · g0 · 2026-10-06 | non | pharmacies, pharmacie_credentials, service_providers, admins, restaurant_owners, subscription_operations, wallet_transactions | ÉLEVÉ | L1 — Garde en tête + tombstone dans la transaction (débit wallet, auth.updateUser) |
| moderateVehicleEntity | Auto & Moto (admin) | callable · g0 · 2026-10-06 | non | real_estate_agents, real_estate_listings, real_estate_private_locations, admins, audit_logs, vehicle_seller_suspensions | MOYEN | L2 — Garde sur le vendeur cible |
| notifyAdminsOnEventProviderApplication | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyAdminsOnNewDriver | Notifications / triggers | trigger · g0 · 2026-10-06 | non | admins | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyAdminsOnNewServiceProvider | Notifications / triggers | trigger · g0 · 2026-10-06 | non | admins | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyAgentOnVisitRequest | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyBoulangerieOnNewOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | boulangeries | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyBroadcastDrivers | Notifications / triggers | trigger · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnBoulangeriePreparation | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnEventReservationUpdate | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnOrderCreated | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnOrderUpdate | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnRecharge | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyClientOnVisitUpdate | Notifications / triggers | trigger · g0 · 2026-10-06 | non | admins, event_providers, clients, event_chats | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyDriverLowBalance | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyDriverOnAssigned | Notifications / triggers | trigger · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyDriverOnMissionEnd | Notifications / triggers | trigger · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyDriverOnOrderCancelled | Notifications / triggers | trigger · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyDriversOnNewOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkAgentOnAssigned | Notifications / triggers | trigger · g0 · 2026-10-06 | non | ekbine_agents | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkAgentOnCompleted | Notifications / triggers | trigger · g0 · 2026-10-06 | non | ekbine_agents | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkAgentOnDepositProof | Notifications / triggers | trigger · g0 · 2026-10-06 | non | ekbine_agents | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkAgentsOnNewOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | ekbine_agents | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkClientOnOrderCreated | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEkClientOnStatusChange | Notifications / triggers | trigger · g0 · 2026-10-06 | non | clients | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyEventChatRecipient | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyPharmacieOnOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | pharmacies | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyProvidersOnEventReservation | Notifications / triggers | trigger · g0 · 2026-10-06 | non | — | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyRestaurantOnOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | restaurant_owners, restaurants | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifySellerOnOrder | Notifications / triggers | trigger · g0 · 2026-10-06 | non | sellers | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| notifyVehicleChatRecipient | Notifications / triggers | trigger · g0 · 2026-10-06 | non | audit_logs, vehicle_seller_suspensions, vehicle_conversations, vehicle_user_blocks, blocked | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| pharmacieLogin | Compte/Auth | callable · g0 · 2026-10-06 | non | pharmacies, pharmacie_credentials | ÉLEVÉ | L1 — Garde en tête |
| republishMarketplaceProduct | Marketplace | callable · g0 · 2026-10-06 | non | marketplace_products, sellers | MOYEN | L2 — Garde en tête |
| requestPropertyVisit | Immobilier | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde en tête |
| resetAccountPassword | Compte/Auth | callable · g0 · 2026-10-06 | non | pharmacie_credentials | ÉLEVÉ | L1 — Garde en tête + refus si le compte cible est en quarantaine (auth.updateUser password) |
| respondToVisitRequest | Immobilier | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde en tête |
| setArtisanPin | Compte/Auth | callable · g0 · 2026-10-06 | non | service_providers, artisan_credentials | ÉLEVÉ | L1 — Garde en tête |
| setPharmaciePassword | Compte/Auth | callable · g0 · 2026-10-06 | non | pharmacies, pharmacie_credentials, admins | ÉLEVÉ | L1 — Garde en tête + refus si la pharmacie cible est en quarantaine |
| staleDriverCleanupCheck | Livraison | HTTP/planifiée · g0 · 2026-10-06 | non | livreurs | FAIBLE | L3 — Aucune |
| submitRealEstateAgentRequest | Immobilier | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde en tête |
| syncDriverOrderLifecycle | Livraison | trigger · g8 · 2026-10-17 | non | livreurs, orders | MOYEN | L3 — NE PAS bloquer : réconciliation à la clôture de commande (n’écrit pas isSuspended) |
| syncPharmacyGuards | Pharmacies | HTTP/planifiée · g0 · 2026-10-06 | non | rate_limits, audit_logs, security_events, admins, pharmacy_guards | MOYEN | L2 — Planifiée : ne pas rétablir de garde pour un propriétaire isDeleted (NON CONFIRMÉ, pharmacyGuards lu partiellement) |
| updateEventProviderRating | Notifications / triggers | trigger · g0 · 2026-10-06 | non | vehicle_conversations, vehicle_user_blocks, blocked | FAIBLE | L3 — Aucune : réagit à un événement Firestore, FCM ou calcul de note ; ne crée ni commande ni mouvement d’argent |
| upsertRealEstateLocation | Immobilier | callable · g0 · 2026-10-06 | non | — | MOYEN | L2 — Garde en tête (localisation personnelle recréée) |
| walletReconciliationCheck | Paiement | HTTP/planifiée · g0 · 2026-10-06 | non | invalid_fcm_tokens, wallet_reconciliation_findings | FAIBLE | L3 — Aucune (contrôle de cohérence) |

Détails d'accès non listés dans le tableau : Auth (`createUser`/`deleteUser`/`updateUser`) seulement dans `createSubAdmin`, `deleteSubAdmin`, `resetAccountPassword`, `manageAdminPartnerAccount`, `setPharmaciePassword` (via `index.js` l.1484), `manageProfessionalSubscription` ; appels externes : FeexPay (`initiateFeexPayPayment`, `initiateWithdrawal`, `checkWithdrawalStatus`, `checkPendingWithdrawals`, `feexPayWebhook` vérification, outil AZ IA `initiate_wallet_recharge`), fournisseurs IA (`azIaChat`) ; FCM : tous les `notify*`, `aiSendDueReminders`, `checkWithdrawalStatus`.

## 5. Les trois listes de protection

**Liste 1 — obligatoire avant activation (16)** : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `azIaChat`, `ekClientConfirmOrder`, `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `createEventReservationCF`, `manageProfessionalSubscription`, `resetAccountPassword`, `setArtisanPin`, `artisanLogin`, `pharmacieLogin`, `setPharmaciePassword`, `manageAdminPartnerAccount`.

**Liste 2 — fortement recommandée (14)** : `clearAiHistory`, `aiSendDueReminders`, `ekbineUpdateDepositAccounts`, `checkWithdrawalStatus` (garde « appelant » sans bloquer la réconciliation), `createSubAdmin`, `deleteSubAdmin`, `republishMarketplaceProduct`, `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `upsertRealEstateLocation`, `moderateVehicleEntity`, `syncPharmacyGuards`.

**Liste 3 — protection non nécessaire ou à ne pas poser (44)** : les 31 triggers (notifications, notes, `syncDriverOrderLifecycle`), `feexPayWebhook`, `checkPendingWithdrawals`, `walletReconciliationCheck`, `cleanupExpiredRateLimits`, `aiCleanupExpiredPendingActions`, `listAiToolExecutions`, `logAuthEvent`, `logAdminAuditEvent`, `checkClientPhone`, `expireMarketplaceProducts`, `diagnoseDriverOccupancy`, `staleDriverCleanupCheck`, `fcmTokenCleanupCheck`. Justification : réconciliation d'opérations antérieures (à ne jamais bloquer), lecture seule, ou notification sans effet sur un compte.

Aucune réduction artificielle : `artisanLogin`/`pharmacieLogin` sont en liste 1 par prudence (**NON CONFIRMÉ** que ce soit une opération sensible — le code lu n'émet pas de jeton) ; si le code montre qu'elles sont en lecture seule, elles passent en liste 2.

## 6. Fichiers locaux et points d'entrée à corriger

La garde générique existe déjà dans le local : le wrapper `onCall` de `functions/index.js` (l.79-85) appelle `assertAccountEnabled(db, request.auth?.uid, HttpsError)` avant **tous** les callables, y compris ceux injectés dans `azia/` et `realestate.js` (ils reçoivent le `onCall` encapsulé, l.2652-2695). Redéployer ces fonctions depuis le local **donne la garde en tête** sans modification de code. Il reste à ajouter la **relecture dans la transaction** (anti-concurrence) :

| Fichier | Point d'entrée | Contrôle à ajouter | Opérations à bloquer |
|---|---|---|---|
| `functions/index.js` l.373 (`initiateFeexPayPayment`) | avant `txRef.set` | lecture `account_tombstones/{uid}` + `isDeleted` du profil ; échec `ACCOUNT_DELETION_IN_PROGRESS` | nouvelle recharge |
| `functions/index.js` l.608 (`initiateWithdrawal`) | dans `runTransaction`, après lecture du profil | idem via `assertNewAccountActivity` | débit + payout |
| `functions/azia/pendingActions.js` `buildConfirmAction` | début de la transaction de confirmation | relecture tombstone ; refuser `confirm`, **autoriser `cancel`** | tout `confirmHandler` |
| `functions/azia/index.js` (`azIaChat`) | entrée | garde (déjà par wrapper) | nouvelles actions, mémoire, rappels |
| `functions/index.js` l.2017-2115 (E-Kbine) | transactions | `assertNewAccountActivity` pour client et agent | confirmation/acceptation/dépôt |
| `functions/eventReservations.js`, `professionalSubscriptions.js` | transaction wallet | `assertNewAccountActivity` (déjà présent pour `eventReservations` en local, à vérifier pour les abonnements) | débit wallet |
| `functions/index.js` l.1574-1855, `adminPartnerAccounts.js`, `passwordReset.js` | avant `auth.updateUser` | refus si le compte **cible** a un tombstone | changement de mot de passe/PIN |
| `functions/feexpayPayments.js` `processFeexPayWebhookEvent` | transaction de crédit | **ne pas bloquer** ; poser `creditedAfterDeletion:true` + `logSecurityEvent` si le profil est `isDeleted`/tombstone | — (journalisation) |

Concurrence : le moteur inspecte puis crée le tombstone dans une transaction, puis réinspecte après 15 min. Une opération qui se glisse entre ces instants et le tombstone n'est arrêtée que si la **garde est relue dans sa propre transaction** (lecture du document `account_tombstones/{uid}` ajoutée au jeu de lecture : le conflit est détecté à l'écriture du tombstone). **NON CONFIRMÉ** : comportement exact des requêtes de plage du moteur (`wallet_transactions where userId==`) face à une insertion concurrente (verrouillage de plage non garanti côté Admin SDK).

Opérations engagées à terminer / réconcilier : retraits `processing` (scheduler), collects `pending` (webhook + vérification serveur), actions AZ IA `pending` (expirer/annuler, jamais confirmer), commandes en cours (`inspect()` bloque le dossier). Intervention administrative : les callables admin (support, recharges) doivent rester possibles sur un compte en quarantaine (`adminWalletRequests`, `manageAccountDeletionCF` sont des fonctions admin du moteur, hors liste).

## 7. Tests à préparer (local / émulateur, jamais en production)

1. Compte actif : recharge, retrait, confirmation AZ IA, mots de passe, E-Kbine fonctionnent (régression nulle) — pour chaque fonction de la Liste 1.
2. Compte avec `account_tombstones/{uid}` : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction(confirm)`, `azIaChat`, E-Kbine, `createEventReservationCF`, `manageProfessionalSubscription`, changements de mot de passe → `ACCOUNT_DELETION_IN_PROGRESS`, aucune écriture (assert sur Firestore émulé).
3. Ancien jeton : appeler avec un `request.auth` dont l'UID a un tombstone et un Auth supprimé (le callable testé via `.run(request)`) → refus.
4. `aiConfirmAction(cancel)` reste possible ; `confirm` refusé sur action `pending` préparée avant quarantaine.
5. Webhook : collect `pending` créé avant tombstone, succès vérifié après tombstone → crédité, `creditedAfterDeletion:true`, security_event, pas de double crédit ; webhook rejoué → `already_processed`.
6. Retrait `processing` avant tombstone : le scheduler le termine/compense sans erreur.
7. Compte supprimé (`isDeleted`) : `initiateWithdrawal` → `not-found`/refus ; aucune écriture sur l'ancien profil.
8. Admin : opérations de support sur un compte en quarantaine autorisées.
9. Comptes sans tombstone : aucune lecture supplémentaire bloquante (mesurer le nombre de lectures ajoutées par la garde, 1 `get`).
10. Concurrence : recharge lancée pendant la création du tombstone (émulateur, deux transactions entrelacées).

## 8. Limites de l'analyse

- Extraction **statique heuristique** des collections ; relecture manuelle ciblée (paiements, AZ IA, E-Kbine, comptes, abonnements, réservations) ; les 31 triggers et les 10 planifiées/HTTP non financières n'ont pas été relues ligne à ligne.
- Le diff déployé/local des modules qui diffèrent (liste §1) n'a pas été détaillé.
- Aucun test dynamique, aucun appel de fonction, aucune lecture de données de production.
- Comportement de FeexPay (délais de callback, relances de webhook) : **NON CONFIRMÉ**.
- Durée de validité du jeton ID (≈1 h) : comportement documenté Firebase, non testé ici.
- `syncPharmacyGuards`, `pharmacyGuards.js`, `eventNotifications`, `vehicleChatNotifications` : lecture partielle.

## 9. Points nécessitant une décision technique

- **D1 — Webhook FeexPay sur profil en suppression** : (a) créditer et signaler (`creditedAfterDeletion`, alerte support) — recommandé, aucun paiement orphelin ; (b) refuser et créer un dossier de remboursement manuel. Ne jamais répondre 4xx sans file de reprise.
- **D2 — Durée de la fenêtre jeton** : accepter ≈1 h de risque résiduel pour les fonctions non gardées de Liste 3, ou invalider via `checkRevoked` (changement hors périmètre, coûteux en latence).
- **D3 — Comptes admin / sous-admin** : la suppression est-elle supportée ? Sinon, bloquer en revue manuelle côté moteur.
- **D4 — `artisanLogin`/`pharmacieLogin`** : confirmer l'absence d'émission de jeton avant de les classer.
- **D5 — Redéploiement des modules divergents** : accepter d'embarquer les différences local/prod (liste §1) ou isoler.

## 10. Nombre exact de fonctions à protéger avant activation

**16** (Liste 1). **30** si l'on inclut la Liste 2. Les 44 restantes ne doivent pas être gardées (ou ne le nécessitent pas). Les 21 fonctions déjà gardées en production (g1-g7) ne sont pas concernées ; les 4 fonctions de suppression sont à déployer en plus.

**Conclusion** : les 4 fonctions de suppression ne doivent pas être activées avant déploiement du lot de 16 (dont 3 CRITIQUE/ÉLEVÉ financiers : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`). Rien n'a été déployé, modifié ou commité.
