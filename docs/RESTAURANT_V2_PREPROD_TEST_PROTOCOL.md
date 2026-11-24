# Restaurant v2 — protocole d'essais en préproduction (Mission 7E-35)

Statut : **PLAN, rien n'est exécuté.** Révisé en Mission 7E-36 d'après la répétition locale complète (`functions/test/restaurantV2Pilot.emulator.test.js`, vrais modules de `functions/`, émulateur Firestore). Scripts : `scripts/restaurant-v2-pilot/` (voir son README). Projet cible : `az-express-preprod` (n° 306761725053, europe-west1). Production `az-express-b0469` interdite.
Toute commande Firebase/gcloud porte `--project az-express-preprod` (le défaut de `.firebaserc` est la production).

## 0. Principes

- Comptes et données **fictifs**, identifiants préfixés `t7e-` (client `t7e-client`, restaurant `t7e-resto`, livreur `t7e-driver`, admin `t7e-admin`), pour un nettoyage ciblé sans toucher aux données existantes.
- Aucun paiement externe : `paymentMethod` = `wallet` (solde fictif) ou `cash` (simple déclaration, aucun mouvement de wallet).
- Aucune notification : les comptes fictifs n'ont **aucun** `fcmToken`, et `NOTIFICATIONS_SEND=off` (garde `notificationGuard`) reste en place. Double barrière.
- Aucun SMS : ne jamais renseigner de téléphone destinataire pour la preuve de livraison (`deliveryProofSms.js`) ; QR/PIN affichés seulement dans la réponse de `prepareOrderProof`.
- Aucun secret lu en clair. Le pepper reste dans Secret Manager.
- Statuts `orders` inchangés : `pending → broadcast/assigned → accepted → picked_up → delivered` ou `cancelled`.
- Une étape = un constat noté (document, valeur, horodatage). Arrêt immédiat au premier FAIL inattendu.

## 1. Comptes fictifs (à créer APRÈS autorisation)

| Rôle | Collection | Contenu minimal | Wallet de départ |
|---|---|---|---|
| Client | `clients/t7e-client` | `name`, `email`, `wallet` ; compte actif | 40 000 FCFA |
| Restaurant | `restaurants/t7e-resto` + `restaurant_owners/t7e-resto` + `menu/t7e-plat-a` (2 500) et `menu/t7e-plat-b` (1 500) | `isActive`, `isOpen`, `lat/lng`, sans `openTime/closeTime` (aucune plage horaire) | 0 |
| Livreur | `livreurs/t7e-driver` | `isOnline`, `isAvailable`, `lat/lng` à ~30 m du restaurant, `currentCityId: abengourou`, `updatedAt` < 3 min (à rafraîchir avant S6 : `prepare.js --refresh-driver-gps`) | 5 000 FCFA |
| Admin | `admins/t7e-admin` | super-administrateur (requis pour décisions de remboursement et config pilote) | — |

Les 4 identités ont aussi un utilisateur Firebase Auth créé avec **uid explicite** (`t7e-client`, `t7e-resto`, `t7e-driver`, `t7e-admin`), e-mail `@example.invalid`, mot de passe aléatoire écrit hors dépôt, aucun SMS. L'uid du restaurant DOIT être l'identifiant de son document : `partnerOrderActionCF` exige `order.sellerId == uid`, et `restaurant_owners/<uid>.restaurantId` sert à émettre la preuve de récupération. Les schémas sont figés dans `scripts/restaurant-v2-pilot/lot.js` (chaque champ vient d'une lecture du code déployé). Zone de service : `zones_livraison/abengourou-test` (existante). Point de livraison : 6.7345, -3.4890.

## 2. Invariants financiers (v2, d'après `partnerOrderAmounts.js` / `orderActions.js`)

`totalAmount = productAmount + deliveryFee`, `budget = deliveryFee`.
- Création (wallet) : client −`totalAmount`, journal `order_<orderId>`. Aucun crédit partenaire ni livreur.
- Acceptation livreur : commission prélevée **une seule fois** (`commissionAmount`, plafonnée aux frais), `commissionStatus: charged`.
- Livraison : partenaire +`productAmount` (aucune commission sur les produits), livreur +`deliveryFee`. En cash : aucun mouvement, `cashRemittance` posé.
- Annulation avant préparation : client remboursé de `totalAmount`, commission rendue au livreur payeur.
- Contrôle global à chaque étape : Σ wallets (client + resto + livreur) ne varie que de la commission ; jamais de solde négatif ; aucune écriture doublée dans `wallet_transactions` / `commissions`.

## 3. Scénarios

Notation : **Pré** préconditions · **Act** actions · **Att** résultat attendu · **Doc** documents · **Fin** contrôle financier · **PASS/FAIL**.

### S1 — Activation contrôlée du pilote
- Pré : `config/partnerOrdersV2` absent (404) ; variable `PARTNER_ORDERS_V2=on` déjà déployée ; admin fictif connecté.
- Act : `partnerOrderActionCF` avec `{action:'setPartnerOrdersConfig', patch:{pilotPartnerIds:['t7e-resto'], creationOpen:true}, expectedVersion:0, reason:<10 à 300 car.>}` par `t7e-admin` (super-administrateur). Charge utile exacte : `lot.pilotConfigPlan()`.
- Att : document `{pilotPartnerIds:['t7e-resto'], creationOpen:true, managementFrozen:false, version:1, updatedBy, lastChange}` ; audit `partner_orders_config_update` avant/après. Avant l'ouverture : devis refusé `PARTNER_NOT_IN_PILOT`.
- Doc : `config/partnerOrdersV2`, `audit_logs`.
- Fin : aucun mouvement.
- PASS : liste = `t7e-resto`, `creationOpen=true`, audit présent. FAIL : tout autre partenaire listé.
- Contre-test : un devis pour un autre `sellerId` doit être refusé (`CREATION_CLOSED`/`PARTNER_NOT_IN_PILOT`).
- Nettoyage final : `cleanup.js` ferme (`creationOpen:false`, liste vide) PUIS supprime le document → 404, après tout le reste des suppressions Firestore.

### S2 — Devis Restaurant v2
- Pré : S1 faite ; client fictif.
- Act : `quotePartnerOrderCF` avec `sellerType:'restaurant'`, `sellerId:'t7e-resto'`, `items:[{itemId,qty}]` (panier de référence : 2×plat A + 1×plat B = 6 500 FCFA), `destination{lat,lng}`.
- Att : enveloppe `{success:true,...}` ; `productAmount` relu côté serveur ; `deliveryFee` du barème officiel ; `totalAmount` ; devis lié au client, expirant, à usage unique.
- Doc : `tariff_quotes/<quoteId>`.
- Fin : aucun mouvement de wallet.
- PASS : montants = calcul attendu (prix menu × quantités + barème). FAIL : montant dicté par le client accepté, ou wallet modifié.

### S3 — Création de commande
- Act : `createPartnerOrderFromQuoteCF` (mêmes choix que le devis + `quoteId`, `paymentMethod:'wallet'`, `confirmedAmount` = total du devis, `deliveryAddress`).
- Att : ordre `status:'pending'`, `amountsVersion:2`, `sellerType:'restaurant'`, `totalAmount` débité. Montants de référence : tarif de jour, frais 500 → total 7 000, commission 100 ; tarif de nuit, frais 1 000 → total 7 500, commission 200. Toujours recalculer avec `lot.expectedAmounts({nowMs})`.
- Doc : `orders/<id>`, `clients/t7e-client`, `wallet_transactions`.
- Fin : client −`totalAmount` exactement ; resto et livreur inchangés.
- Rejeu : même `quoteId` → même commande, aucun second débit. Devis expiré/déjà utilisé d'un autre client → refus.
- PASS : un seul débit, journal `order_<id>`.

### S4 — Acceptation par le restaurant
- Act : `partnerOrderActionCF` `acceptPartnerOrder` (ou `acceptAndPrepare`) par `t7e-resto` (uid = `sellerId`).
- Att : `partnerAcceptedAtMs` posé ; la fonction lance le dispatch ; aucun mouvement d'argent.
- Contrôle : un autre restaurant/compte ne peut pas agir (refus).

### S5 — Préparation
- Act : `startPreparation` puis `markReady` (`markReady` exige l'état `preparing`).
- Att : `sellerStatus` progresse ; l'annulation simple n'est plus possible sans décision admin (garde `PREPARATION_STARTED`).
- Fin : aucun mouvement.

### S6 — Attribution au livreur
- Act : dispatch automatique lancé par l'acceptation du restaurant ; `t7e-driver` en ligne, GPS < 3 min (rafraîchir juste avant), solde ≥ commission, rayon 2 km.
- Att : avec **un seul livreur éligible**, la commande passe directement à `status:'assigned'`, `driverId = t7e-driver` (constaté en répétition locale) ; `broadcast` n'apparaît qu'avec plusieurs livreurs.
- Notification : **aucun envoi FCM** (pas de token + garde OFF) ; journal « envoi bloqué » accepté.

### S7 — Acceptation du livreur
- Pré : **selfie d'acceptation obligatoire** : objet Storage `acceptance_selfies/<orderId>/t7e-driver.jpg` (image fictive ≤ 5 Mo) déposé AVANT l'appel ; `acceptanceSelfieUrl` = URL de téléchargement Firebase de cet objet (bucket du projet).
- Act : `acceptOrderCF {orderId, acceptanceSelfieUrl}` par `t7e-driver`.
- Att : `status:'accepted'`, `driverId`, `driverAssignmentVersion`, `commissionStatus:'charged'` ; offres résiduelles nettoyées.
- Fin : livreur −commission (une seule fois) ; `commissions` +1.
- Rejeu : 2 appels identiques → `alreadyAccepted:true`, une seule commission. (Un seul livreur fictif : pas de course entre deux livreurs.)

### S8 — Preuve de récupération (QR/PIN)
- Pré : `sellerStatus:'ready'` (sinon refus : « pas encore prête »).
- Act : `prepareOrderProof {orderId, type:'pickup'}` par **le restaurant** (`t7e-resto`, via `restaurant_owners`), jamais par le livreur ; le livreur confirme avec `confirmOrderPickupWithProof {orderId, token|pin}`.
- Att : preuve `active` puis `used` ; TTL 15 min ; 3 générations max par affectation.
- Négatifs : mauvais PIN ×5 → `pinLocked` ; preuve d'une autre commande, autre livreur, expirée → refus ; QR+PIN ensemble → refus.

### S9 — Passage à `picked_up`
- Att : `status:'picked_up'`, `deliveryProofMode:'qr_v1'`. Rejeu de la confirmation → `failed-precondition`, rien ne change.
- Concurrence : 3 QR + 3 PIN simultanés → un seul passage (déjà validé sur émulateur, à reconfirmer en cloud sur UNE commande).

### S10 — Preuve de livraison (QR/PIN)
- Act : `prepareOrderProof {orderId, type:'delivery'}` par **le client** (`t7e-client`) ; le livreur confirme avec `confirmOrderDeliveryWithProof {orderId, proofToken|proofPin}`.
- Négatifs : même suite qu'en S8 ; livraison sans preuve (`deliverOrderCF` direct) refusée pour une commande `qr_v1`.

### S11 — Passage à `delivered`
- Att : `status:'delivered'`, `deliveryProofValidatedBy = t7e-driver`, preuve `used` ; tout dans UNE transaction.
- Fin : voir S12.

### S12 — Commissions et wallets
- Fin attendu après S11 : resto +`productAmount` ; livreur +`deliveryFee` (net de la commission déjà prélevée en S7) ; client inchangé depuis S3 ; une seule ligne `earning` par bénéficiaire ; `commissions` : exactement 1 pour la commande.
- Contrôle de conservation : Σ(wallets) après = Σ(wallets) avant S3 − commission.
- PASS : égalités exactes en FCFA entiers, aucun doublon. FAIL : écart d'un seul FCFA.

### S13 — Annulation et remboursement (simulés)
- A : `cancelOrderCF {orderId}` par le client avant acceptation du restaurant → remboursement `totalAmount`. B : `refusePartnerOrder` avant acceptation → même remboursement. C : livreur accepté (commission prélevée), puis `refusePartnerOrder` avant préparation → client remboursé du total ET commission rendue au livreur payeur. D : solde client insuffisant → refus, aucun débit. (Tous constatés en répétition locale ; `refusePartnerOrder` est impossible après `startPreparation`.)
- Fin : retour exact au solde initial ; jamais de solde négatif ; double annulation = aucun second remboursement.
- « Simulé » : wallets fictifs uniquement, aucun remboursement externe.

### S14 — Litige et confirmation admin
- Commande C livrée en cash ou bloquée : `adminOrderDisputeCF` action `get` puis `decide` (`resolve`, `refundShopping`, `refundFee`, `refundHalfFee`, `exceptionalCancel`) avec `justification` et `requestId` (16–128 car.). Décisions de remboursement = super-admin.
- `adminConfirmDeliveryCF` pour une commande sans preuve exploitable.
- Att : audit `admin_order_dispute`, montants conformes à la décision, rejeu avec même `requestId` = `replay:true` sans second mouvement.
- Négatif : admin non super-admin refusé sur une décision de remboursement.

### S15 — Expiration automatique
- Contrainte : `autoExpireOrders` tourne chaque minute ; elle n'expire une commande v2 non acceptée qu'après **60 min** (`PARTNER_RESPONSE_TIMEOUT_MS`), les autres après 10 min.
- Option 1 : laisser une commande v2 non acceptée 60 min (sans écriture supplémentaire).
- Option 2 (écriture cloud à autoriser séparément) : antidater `createdAt` d'une commande fictive.
- Att : `status:'cancelled'`, remboursement client intégral, audit `order_auto_cancelled_no_driver`, aucun doublon à la minute suivante.
- Avant : lecture seule du nombre de commandes `pending/broadcast/assigned` existantes non fictives (le planificateur les traite aussi).

### S16 — Rejeu et concurrence (cloud, volume minimal, `maxInstances=1`)
- Double appel de `createPartnerOrderFromQuoteCF`, double acceptation livreur, double confirmation QR/PIN, double décision admin.
- Att : un seul effet ; autres réponses `failed-precondition`/`aborted`/`replay`.
- Pas de test de charge ; au plus 4 appels parallèles par cas.

### S17 — Notifications bloquées
- Att : zéro appel FCM (aucun token + `NOTIFICATIONS_SEND=off`). Preuve : absence de `notification_dedupe` créé pour ces événements, logs « envoi bloqué » des 3 fonctions notify, aucune erreur.
- Aucun test « NOTIFICATIONS_SEND=on » dans ce protocole (mission distincte, appareil de l'équipe, empreinte de token).

### S18 — Journaux et audit
- `audit_logs` : une entrée par action sensible (config, création, acceptation, preuves, livraison, litige, expiration).
- `gcloud logging read` sur les services concernés : aucune sévérité ≥ ERROR inattendue ; aucun secret/PIN/token en clair dans les logs.
- Vérifier que seuls des hachages (`tokenHash`, `pinHash`) existent dans `delivery_proofs`.

## 4. Nettoyage des données fictives

Ordre : (1) fermer le pilote (`creationOpen:false`, liste vide) puis supprimer `config/partnerOrdersV2` → 404 ; (2) supprimer les documents dont l'id/`clientId`/`driverId`/`sellerId` commence par `t7e-` : `orders`, `tariff_quotes`, `delivery_proofs` (+ `versions`), `commissions`, `wallet_transactions` des 3 comptes, `notification_dedupe` éventuels, `rate_limits` ; (3) supprimer les 4 comptes de rôle et les 4 utilisateurs Auth ; (4) **conserver** `audit_logs` (traçabilité, écriture serveur seule). Contrôle final : requêtes de dénombrement = 0 pour le préfixe, wallets réels inchangés.
Le nettoyage est une opération cloud d'écriture : script limité au préfixe `t7e-`, d'abord en mode « liste seule » (lecture), puis suppression après autorisation.

## 5. Sécurité — ce que le plan n'exige pas

Aucun paiement réel (wallets fictifs, pas de FeexPay) · aucun SMS (pas de numéro destinataire) · aucun FCM (pas de token, garde OFF) · aucun compte de production · aucun secret en clair · aucune écriture en production · aucune règle Firestore/Storage modifiée · aucun déploiement.

## 6. Opérations cloud nécessitant une autorisation séparée

1. Création des 4 utilisateurs Firebase Auth fictifs.
2. Écriture des documents de départ (`clients`, `restaurants` + `menu`, `restaurant_owners`, `livreurs`, `admins`, wallets) : `prepare.js --execute`, lot unique `create()` (refus si l'un existe).
2 bis. Objets Storage `acceptance_selfies/<orderId>/t7e-driver.jpg` (un par commande acceptée) : **nouveau** par rapport à la version précédente du plan.
2 ter. Rafraîchissement du GPS du livreur fictif avant chaque dispatch (`prepare.js --refresh-driver-gps`).
3. Écriture de `config/partnerOrdersV2` par `partnerOrderActionCF` (ouverture du pilote restreinte à `t7e-resto`), jamais par les scripts.
4. Chaque lot d'appels de fonctions créant des commandes (S3, S13, S14, S15) — idéalement une autorisation par lot.
5. Éventuel antidatage de `createdAt` (S15, option 2).
6. Connexion des comptes fictifs (mot de passe ou jeton personnalisé) pour appeler les fonctions : authentification uniquement.
7. Nettoyage : `cleanup.js` d'abord en DRY-RUN (inventaire + empreinte), puis `--execute` avec l'empreinte relue ; ferme le pilote avant de supprimer.
8. Toute activation de `NOTIFICATIONS_SEND=on` (hors de ce protocole).

## 7. Risques et préconditions

- `autoExpireOrders` (chaque minute, ENABLED) agit aussi sur d'éventuelles commandes non fictives en attente : à dénombrer en lecture avant S1.
- Les tokens FCM réels de préproduction n'appartiennent pas aux comptes fictifs ; ne jamais copier ces tokens.
- Quota Cloud Run : Σ cpu×maxInstances = 17,5 sur 20 ; aucune augmentation d'instances pendant les essais.
- L'horaire du restaurant (`openTime/closeTime`) est évalué en UTC : choisir une plage couvrant l'heure d'essai.
- Les fonctions FeexPay et AZ IA ne sont pas déployées : aucun scénario ne doit en dépendre.
- La preuve QR/PIN prouve la détention du code, pas la remise physique du colis.
