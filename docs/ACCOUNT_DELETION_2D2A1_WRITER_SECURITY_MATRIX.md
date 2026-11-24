# 2D-2A.1 — Matrice de sécurité des writers financiers face à la suppression de compte

Spécification d'audit uniquement. HEAD `d65c8f0`, index vide. Aucun writer, règle, inspecteur ni test n'a été modifié.

## 0. Méthode et limites

- Audit **statique** : recherche des références `assertNewAccountActivity`, `account_tombstones`, `deletionRequested`, `isDeleted` dans chaque module, puis lecture ciblée des points de crédit/débit. Je n'ai pas exécuté ces fonctions et je n'ai pas lu chaque ligne de chaque writer. Une case « non garanti » signifie « aucune garde trouvée par cette méthode », pas « faille démontrée ».
- Garde de référence : `assertNewAccountActivity(tx, db, HttpsError, uid, partners)` (`accountAdmission.js:2-13`). Elle **relit dans la transaction du writer** le marqueur `account_tombstones/{uid}` puis les profils (`deletionRequested`, `isDeleted`). Parce qu'elle lit le même document que la quarantaine crée (`accountDeletion.js:88`), les deux transactions se sérialisent **sur ce document** : le premier qui valide force l'autre à relire **[C : lecture de code ; la sérialisation relève du comportement des transactions Firestore, non testé ici]**.
- Barrière de règles : `isAuth()` refuse toute écriture/lecture d'un client dont `account_tombstones/{uid}` existe (`firestore.rules:7-11`). Elle ne protège que les accès **client** ; l'Admin SDK des Cloud Functions l'ignore **[C]**.
- Effet de la quarantaine sur le profil : `isOnline:false`, `isAvailable:false`, `isSuspended:true` (`accountDeletion.js:89`) ; `inspect()` exige `wallet === 0`, aucune dette, aucune mission (`accountDeletion.js:31-39`) **[C]**.

## 1. Writers dotés d'une garde dans leur transaction

| Writer (export) | Module:ligne de garde | Parties protégées | Remarque |
|---|---|---|---|
| `createOrderFromQuoteCF` | `deliveryQuote.js:199` | client | création de commande + débit wallet |
| `createCatalogOrderFromQuoteCF` | `catalogQuote.js:189` | client | idem |
| `createPartnerOrderFromQuoteCF` | `partnerOrderQuote.js` (import l.25) | client | garde importée ; ligne d'appel non relue **[non confirmé]** |
| `payBoutiqueOrderCF` | `orderActions.js:1337` | client, vendeur | |
| `payBoutiqueOrderCashCF` | `orderActions.js:1540` | client | |
| `initiateFeexPayPayment` | `index.js:457` | demandeur | recharge |
| `initiateWithdrawal` | `index.js:675` | demandeur | retrait |
| `feexPayWebhook` (crédit) | `feexpayPayments.js:510-514, 634` | bénéficiaire | profil anonymisé ⇒ crédit refusé ; tombstone antérieur à la demande ⇒ mise en attente |
| `adminApproveRechargeCF` (via `adminWalletRequests`) | `adminWalletRequests.js:83` | cible | |
| `adminDriverRechargeCF` | `adminDriverRecharge.js:83` | livreur cible | |
| `ekCreateOrderCF` | `ekbineOrders.js:148` | client | |
| `ekbineAcceptOrder` | `ekbineOrders.js:354` | agent | |
| `ekClientConfirmOrder` | `ekbineOrders.js:309` | **agent** (`agentId`), pas le client | le client qui confirme n'est pas relu |
| Réservations d'événements | `eventReservations.js:102` | client | |

## 2. Writers sans garde de suppression détectée

Légende des colonnes : *Peut créer une obligation* = crée ou modifie une dette, un flag, un règlement ou un montant dû ; *Peut créditer un compte anonymisé* = écrit un solde ou un journal sur un profil ayant `isDeleted:true` ; *Modifie après inspection* = agit sur une commande ou un règlement déjà terminés.

| Writer (export) | Module | Contrôle de suppression trouvé | Peut créer une obligation | Peut créditer un compte anonymisé | Modifie après inspection | Correction nécessaire (non faite) |
|---|---|---|---|---|---|---|
| `cancelOrderCF` | `orderActions.js:494` | aucun | oui (remboursement, `refundPending`, flag `commission_untraced` via la transaction d'annulation, `orderActions.js:422`) | oui (remboursement client ou commission livreur) | commande non terminale seulement | garde `assertNewAccountActivity` sur client et livreur |
| `deliverOrderCF` | `orderActions.js:569` | aucun | oui (règlement `transfer_settlements`, flags `partner_credit_missing` l.898, `cash_payment_review` l.1017) | oui (gain livreur, crédit partenaire) | commande en cours seulement | garde sur client, livreur, vendeur |
| `adminConfirmDeliveryCF` | `orderActions.js` (même builder) | aucun | idem | idem | idem | idem |
| `payOrderFromWalletCF` | `orderActions.js:48` | aucun | oui (débit client + journal hors transaction l.142) | non | commande en cours | garde sur client |
| `refundExpiredBoutiqueOrderCF` | `orderActions.js:1657` | aucun | oui (remboursement) | oui (client) | commande boutique expirée | garde sur client |
| `autoExpireOrders` (planificateur) | `index.js:2174` | aucun trouvé | oui (remboursement wallet automatique l.2256) | oui (client) | commande non terminale seulement | garde ou saut des comptes avec tombstone |
| `acceptOrderCF` | `driverAcceptance.js` | **partielle** : refuse `deletionRequested`, `consentVerified`, `isSuspended` du livreur (l.136-142) | oui (commission) | non | non | acceptable ; vérifier le client |
| `releaseOrderBeforePickupCF` | `driverRelease.js` | aucun | oui (flag `commission_untraced_<uid>` l.134, remboursement commission) | oui (livreur) | commande acceptée | garde sur livreur |
| `deliveryTransferCF` | `driverTransfer.js` | **partielle** : bénéficiaire refusé si `deletionRequested`/`isSuspended` (l.60, 441) | oui (règlement) | non | non | acceptable |
| `settleTransferEarningsCF` | `transferSettlement.js:100-140` | aucun | non (exécute un règlement) | **oui** (crédite chaque livreur de la chaîne, l.106-120) | **oui** (règlement `pending_review` créé avant, approuvé après inspection) | refuser/mettre en attente le crédit d'un livreur avec tombstone |
| `adminBillingCF` | `adminBilling.js` | aucun | oui (`fee_hold_*`, `admin_refund_*` l.153-305) | oui (client, vendeur) | **oui** (commandes terminées) | garde sur chaque bénéficiaire |
| `adminOrderDisputeCF` | `adminOrderDisputes.js` | aucun | oui (flags `seller_review`, `driver_advance_unreimbursed` l.505-525, crédits l.473-486) | oui (client, livreur) | **oui** (commandes livrées) | garde sur chaque bénéficiaire |
| `partnerOrderActionCF` | `partnerOrderActions.js` | aucun | oui (flags `cash_payment_review` l.242, `cash_shortfall` l.361) | possible (partenaire) | **oui** (commandes espèces livrées) | garde sur client, partenaire |
| `ekCancelOrderCF` | `ekbineOrders.js:199-272` | aucun | oui (remboursement, flag `ekbine_cancel_unproven_debit`) | oui (client) | commande en cours | garde sur client |
| `adminApproveWithdrawalCF` | `index.js:2800` | aucun trouvé | non | non | demande en attente | à auditer ; `pendingWithdrawal` bloque déjà `inspect()` |
| `checkWithdrawalStatus`, `checkPendingWithdrawals` | `index.js:816` | aucun trouvé | oui (remise/ré-imputation selon statut) | possible | demande antérieure | à auditer **[non confirmé]** |
| `ekbineAgentDepositAction`, `ekbineSubmitDepositProof` | `ekbineFlow.js` | `ekbineFlow.js:34` (agent) | possible | agent | — | hors moteur ; agents Ekbine conservent leurs protections |
| `walletReconciliationCheck` | `index.js` | n'écrit pas de solde (journal de détection) | non | non | non | aucune |

Remarques **[C]** :
1. Aucun des writers ci-dessus ne lit `account_tombstones` : une opération administrative ou planifiée peut donc modifier un compte en quarantaine, par Admin SDK, sans y être empêchée par les règles.
2. Les flags créés après inspection (`seller_review`, `driver_advance_unreimbursed`, `cash_payment_review`, `cash_shortfall`, `commission_untraced`) sont les obligations que le moteur sait détecter : leur apparition entre la dernière inspection et la suppression est le risque central.
3. Les transactions de `deliverOrderCF`, `adminBillingCF`, `adminOrderDisputeCF` ne lisent pas le document tombstone ; elles ne se sérialisent donc pas avec la quarantaine sur ce document. Elles se sérialisent éventuellement sur le document de profil si elles l'écrivent (crédit de solde), ce qui ferait échouer l'une des deux transactions **[non démontré]**.
4. Écritures hors transaction : `payOrderFromWalletCF` écrit le journal `clients/{uid}/wallet_transactions` après la transaction ; `ekCancelOrderCF` pose son flag et son audit après la transaction (`ekbineOrders.js:249-272`). Un arrêt entre les deux perd l'écriture suivante **[C]**.

## 3. Écritures directes du client (héritage)

Création de commande et débit du solde par Flutter (`delivery_order_service.dart:71`) : protégés par `isAuth()`/`isRealUser()` une fois le tombstone créé **[C]** ; avant le tombstone, la sérialisation avec l'inspecteur passe par le document `clients/{uid}` que les deux transactions lisent/écrivent **[C pour la lecture de code, non démontré pour l'ordonnancement]**.

## 4. Corrections nécessaires avant 2D-2B (propositions)

| Priorité | Correction | Writers concernés |
|---|---|---|
| P1 | Garde `assertNewAccountActivity` (ou variante « bénéficiaire ») dans la transaction de chaque writer qui crée une obligation ou crédite un bénéficiaire | `cancelOrderCF`, `deliverOrderCF`/`adminConfirmDeliveryCF`, `payOrderFromWalletCF`, `releaseOrderBeforePickupCF`, `ekCancelOrderCF`, `refundExpiredBoutiqueOrderCF` |
| P1 | Pour les opérations administratives sur d'anciennes commandes : refuser ou mettre en attente si une partie est sous tombstone | `adminBillingCF`, `adminOrderDisputeCF`, `partnerOrderActionCF`, `settleTransferEarningsCF` |
| P2 | `autoExpireOrders` et `checkPendingWithdrawals` : saut des comptes sous tombstone | planificateurs |
| P2 | Ordre d'écriture : flag/journal dans la même transaction que le fait générateur | `payOrderFromWalletCF`, `ekCancelOrderCF` |
| P3 | Confirmation par lecture complète des cases « non confirmé » | `createPartnerOrderFromQuoteCF`, retraits |

Aucune de ces corrections n'est exécutée ici. Elles modifient du code financier : validation humaine et tests unitaires requis avant toute implémentation.
