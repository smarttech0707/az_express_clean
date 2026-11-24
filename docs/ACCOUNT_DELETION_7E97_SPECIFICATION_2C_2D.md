# Mission 7E-97 — Spécification finale des lots 2C et 2D

Date : 2026-11-09 · HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`, branche `finalisation/az-express`, index vide. **Spécification uniquement** : aucun code modifié, aucun `git add`/commit/push/pull/merge/rebase/reset, aucun déploiement, aucune commande distante, aucun secret, FeexPay non activé, aucune suppression ; production `az-express-b0469` intouchée ; aucun test lancé dans cette mission (lecture seule).
Preuves : **[V]** lu dans le code actuel (HEAD) · **[U]** test existant ou sonde 7E-96 · **[ND]** non déterminé.
Ce document **remplace** pour 2C/2D le découpage du registre 7E-87 §8 (2C-1/2C-2 → nouveaux sous-lots A à D, §9) ; les anciens manifestes n'ont pas été repris tels quels : chaque chemin a été revérifié dans le code actuel.

## 1. Décisions D6 confirmées (définitives, non rouvertes)
| Id | Décision | Traduction technique retenue |
|---|---|---|
| **D6-a** | Bénéficiaire `isDeleted` ⇒ **paiement entier refusé** ; aucun débit, aucun crédit, aucune commission, aucune écriture financière partielle ; motif tracé ; revue administrative ; nouvelle tentative seulement après résolution administrative | garde **dans la transaction** avant toute écriture ; refus `failed-precondition / BENEFICIARY_ACCOUNT_CLOSED` ; la transaction est annulée (donc rien d'écrit), puis **trace séparée** idempotente (§6.4) ; verrou de nouvelle tentative tant que la revue n'est pas levée |
| **D6-b** | Commande **déjà engagée** payable malgré la quarantaine simple du payeur ; nouvelle commande interdite ; exception ciblée au wrapper ; vérification propriétaire, statut, bénéficiaires, finances en transaction ; aucune levée de quarantaine, aucun contournement du tombstone ; anonymisé exclu | wrapper de clôture `onCallClosing` (§5) + `assertClosureActor` en transaction (§6.1) |
| **D6-c** | `cancelOrderCF` / `deliverOrderCF` autorisés à un acteur en **quarantaine simple** : annulation seulement si le statut le permet encore ; livraison seulement par le livreur associé ; rôle, association et statut contrôlés avant toute écriture ; ni nouvelle commande ni nouvelle mission ; anonymisé exclu | même wrapper et même garde d'acteur ; contrôles d'association/statut **déjà présents** (`order.clientId !== uid`, `order.driverId !== uid`, `ORDER_NOT_CANCELLABLE`, statuts livrables) et conservés |
**Règles dérivées** (appliquent D1/D2/D6 par cohérence ; non des décisions nouvelles, à relire à l'autorisation d'implémentation) :
- **DR1** — *Annulation* : si le bénéficiaire d'un **remboursement** (commission rendue au livreur payeur) est `isDeleted`, le remboursement du **client** n'est pas refusé (sinon le client perdrait son argent) : le crédit au profil anonymisé est **omis**, `commissionStatus` reste `charged`, un `reconciliation_flags/{orderId}_beneficiary_closed` ouvert est écrit dans la transaction (modèle déjà utilisé pour `commission_untraced`, `orderActions.js:422`).
- **DR2** — *Livraison* : si le **partenaire** à créditer est `isDeleted`, la livraison est refusée sans écriture (fail-closed défensif ; après 2D ce cas est inatteignable car un partenaire ne peut pas être anonymisé avec une commande non terminale).
- **DR3** — Un acteur dont le profil est **absent** est traité comme anonymisé (refus).

## 2. Matrice acteurs / statuts (état souhaité ; état actuel entre crochets)
Opérations : **N** nouvelle commande (2A/2B, fait) · **P** payer une commande engagée · **A** annuler · **L** livrer · **C** être crédité (bénéficiaire) · **R** être remboursé.
| Acteur | Actif | Quarantaine simple (tombstone, `isSuspended`) | Anonymisé (`isDeleted`) | Profil absent |
|---|---|---|---|---|
| **Client** | N ✔ P ✔ A ✔ R ✔ | N ✘ (fait) · **P ✔ (D6-b)** [✘ wrapper] · **A ✔ (D6-c)** [✘ wrapper] · R ✔ (crédit ⇒ bloque l'anonymisation, §4.4) | tout ✘ (Auth supprimé ; garde en transaction car le jeton reste valide jusqu'à ~1 h) | ✘ |
| **Livreur** | L ✔ C ✔ | N/accepter ✘ (fait) · **L ✔ (D6-c)** [✘ wrapper] · **C ✔** [✔] · retirer ✘ (fait) | L ✘ · **C ✘ ⇒ D6-a/DR1** [✔ crédité : à corriger] | ✘ (refus propre) |
| **Pharmacie / restaurant / boulangerie / vendeur** | C ✔ | C ✔ (restitution) [✔] | **C ✘ ⇒ D6-a (payOrder), DR2 (livraison)** [✔ crédité : à corriger] | ✘ (refus propre) |
| **Administrateur (appelant)** | crédits ✔ | n/a (jamais en quarantaine : `admin_account_manual_review`) | n/a | n/a |
| **Cible d'un crédit admin / règlement / compensation** | ✔ | ✔ (D1/D2) | ✘ refus explicite (admin) / mise en attente (compensation) | ✘ |

## 3. Cartographie des callables (wrapper actuel → souhaité) [V]
Mécanisme actuel : `onCall` local de `functions/index.js:83-90` = `rawOnCall` + `assertAccountEnabled(db, request.auth?.uid, HttpsError)` (`accountDeletion.js:16-19` : refus `permission-denied / ACCOUNT_DELETION_IN_PROGRESS` si `account_tombstones/{uid}` existe). Lecture **hors transaction**, appelant seulement. Quatre exceptions déjà non wrappées (`rawOnCall`) : `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `getPartnerQr`, `resolvePartnerQr`, `listPartnerQrEstablishments`.
| Callable (`index.js`) | Contrôle actuel | Souhaité | Exception ? | Vérification transactionnelle | Risque de contournement |
|---|---|---|---|---|---|
| `payOrderFromWalletCF` (2435) | wrapper bloque le payeur | payeur en quarantaine **autorisé** ; bénéficiaires contrôlés | **OUI** (`onCallClosing`) | acteur + bénéficiaires + statut (§6) | un profil anonymisé avec jeton valide ⇒ garde `isDeleted` en transaction |
| `cancelOrderCF` (2436) | wrapper | client en quarantaine autorisé à annuler | **OUI** | acteur + statut (déjà : propriétaire, `ORDER_*`) | idem |
| `deliverOrderCF` (2439) | wrapper | livreur associé en quarantaine autorisé | **OUI** | acteur + `order.driverId === uid` + statut `accepted/picked_up` (déjà présent) + partenaire (DR2) | idem |
| `confirmOrderDeliveryWithProof` (2507) | wrapper | **même exception que `deliverOrderCF`** (nécessaire : une commande `qr_v1` ne peut pas être livrée par `deliverOrderCF`, `Une preuve de réception est requise`, `orderActions.js` ~l. 666) | **OUI** | idem + preuve QR/PIN conservée | idem |
| `adminConfirmDeliveryCF` (2491) | wrapper (super-admin jamais en quarantaine) | inchangé | non | garde partenaire (DR2) et livreur de référence | — |
| `confirmOrderPickupWithProof`, `prepareOrderProof`, `acceptOrderCF`, `dispatchOrderToDriver`, `releaseOrderBeforePickupCF`, `deliveryTransferCF` | wrapper | **inchangés** (progression/transfert de mission = « nouvelle mission » au sens D6-c) | **non** | — | un livreur en quarantaine avec une commande `accepted` non récupérée ne peut ni récupérer ni libérer : annulation par le client ou action administrative (réserve R4) |
| `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `createOrderFromQuoteCF`, `catalog/partner/ek*` création | wrapper + garde en transaction (2A/2B) | inchangés | non | déjà posée | — |
| `settleTransferEarningsCF`, `adminBillingCF`, `adminOrderDisputeCF`, `adminOrderRefunds*`, `adminApprove*CF` | wrapper (appelant admin) ; **cible non contrôlée** | contrôle de la **cible** (D1/D2) | non | `accountCreditState(cible)` en transaction | cible anonymisée créditée aujourd'hui |
| `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction` | wrapper + garde en transaction (2A) | inchangés | non | déjà posée | — |
**Interdit** : désactiver `assertAccountEnabled` globalement ; faire de `onCallClosing` un `onCall` générique ; l'utiliser pour autre chose que ces **4 fonctions de clôture** (liste fermée, vérifiée par un test de câblage sur `index.js`).

## 4. Spécification du lot 2D (priorité 1) : protéger avant la quarantaine et l'anonymisation
### 4.1 État actuel [V]
- **Trois inspecteurs** : (1) `inspect()` `accountDeletion.js:31-62`, rôles `client` et `livreur` seulement (`ROLES`), interroge `orders` + 4 collections de commandes + `wallet_transactions` + `withdrawal_requests` ; (2) `readDeletionScope()` `accountDeletionScope.js` (partenaires, si `partnerInventoryVersion === 1`, requêtes par `clientId/driverId/sellerId/pharmacieId/restaurantId/boulangerieId`) ; (3) `financialBlocker()` `manualAccountDeletion.js:76-98` (pharmacie, prestataire d'événement). Tout autre rôle : dossier `blocked` / `role_obligations_review_required` (`accountDeletion.js` ~l. 79).
- Les trois utilisent la **même règle** : `!TERMINAL.has(status) || refundPending || needsReview || paymentStatus==='pending'` ⇒ blocage. `delivered` est terminal : **aucun** n'examine `isPaid`, `settlementHold`, `settlementStatus`, `heldDriverEarning`, `deliveryFeeHold`, `cashRemittance`, `merchantCashSettled`, `reconciliation_flags`, `transfer_settlements`, `cancelRequestAfterPickup`.
- `inspect()` est exécuté **deux fois** : avant le tombstone (`accountDeletion.js:85`) et avant l'anonymisation (l. 124, dans la transaction qui pose `isDeleted`). Quand `inspect` bloque, le dossier passe en `blocked`/`cleanup_pending` avec `reviewRequired:true` et `nextAttemptAt = now + RETRY_MS (1 h)` ; `drain()` rejoue **tout dossier échu** ; le plafond `MAX_ATTEMPTS = 6` ne compte que les **exceptions** (`failurePatch`), pas les blocages d'inspection ⇒ **un blocage par obligation se relève tout seul** dès que la condition disparaît, sans plafond, et l'assistance dispose de `retry` (`accountDeletionSupport.js`, `reviewAfter` 24 h).

### 4.2 Module unique d'obligations (nouveau) : `functions/accountObligations.js`
Fonction pure `openObligation(order, role)` → `null` ou un code ; **appelée par les trois inspecteurs** pour chaque document de commande déjà lu (aucune requête supplémentaire pour les commandes). `role` ∈ `client | livreur | partner`.
| Code | Condition exacte (sur le document `orders`) | Concerne |
|---|---|---|
| `unpaid_delivered_wallet` | `status === 'delivered'` ∧ `paymentMethod === 'wallet'` ∧ `isPaid === false` ∧ `type !== 'boutique'` ∧ `amountsVersion !== 2` | client, livreur, partenaire (`pharmacieId`/`sellerId`) |
| `settlement_held` | `settlementHold === true` ∨ `settlementStatus ∈ {'pending_admin_review','cash_pending'}` ∨ (`heldDriverEarning > 0` ∧ `settlementStatus !== 'settled'`) | livreur(s) de la chaîne, client |
| `delivery_fee_held` | `deliveryFeeHold.status === 'pending_admin_review'` | client, livreur |
| `cash_remittance_open` | `cashRemittance` présent ∧ montant dû − confirmé > 0 (vue `partnerOrderActions` l. 70-77) ∨ (`merchantCashSettled === false` ∧ `paymentMethod === 'cash'` ∧ `sellerId`) | livreur, partenaire |
| `cash_nonpayment_open` | `cashPayment` déclaré non payé ∧ non revu | client, livreur |
| `post_pickup_cancel_open` | `cancelRequestAfterPickup.status === 'pending_admin_review'` | client |
| `beneficiary_review_open` | `needsReview === true` ∧ `reviewReason === 'beneficiary_account_closed'` (posé par D6-a) | client, bénéficiaire |
| (existants conservés) | statut non terminal, `refundPending`, `needsReview`, `paymentStatus === 'pending'` | tous |
Deux contrôles **hors commande** (une requête plafonnée à 201 chacune, même règle `history_requires_manual_review` si ≥ 201) : `transfer_settlements` où `status` ∉ `{settled, rejected}` et `holderDriverId`/`driverIds` contient l'uid ; `reconciliation_flags` `status === 'open'` pour l'uid. **Fail-closed** : tout champ de type inattendu ou lecture impossible ⇒ blocage (aucune hypothèse).
Exclusions explicites (pas des obligations) : commande `boutique` (`isPaid` toujours faux, paiement réel sur `boutique_orders`) ; commande `amountsVersion === 2` (réglée à la création) ; commande `cancelled` non payée ; commandes `delivered` payées.

### 4.3 Conditions d'empêchement (distinctions demandées)
| Étape | Condition | Effet |
|---|---|---|
| **Avant la quarantaine** (tombstone) | toute obligation ouverte (§4.2), solde ≠ 0, mission, commande non terminale | dossier `blocked`, `reason:'financial_obligation_pending'` (+ code), **aucun tombstone** : le compte reste pleinement utilisable (il peut régler) |
| **Quarantaine temporaire** (tombstone posé, fenêtre `QUIET_MS` 15 min) | aucune nouvelle activité (2A/2B) ; clôtures engagées permises (D6) | inchangé |
| **Avant l'anonymisation** (relecture dans la même transaction) | obligation apparue pendant la quarantaine ⇒ `cleanup_pending`, `reviewRequired:true`, **tombstone conservé**, nouvelle tentative toutes les heures | l'anonymisation n'a lieu que si **toutes** les obligations sont réglées au même instant transactionnel |
| **Obligation réglée** | le prédicat redevient `null` (payée, soldée `settled`, remise confirmée, revue levée) | le dossier reprend seul au prochain `drain` |
| **Obligation retenue pour revue** | `*_review_open` : reste bloquante jusqu'à décision administrative explicite | `reviewAfter` 24 h + `manageAccountDeletionCF` ; aucune levée automatique |
**Pas de blocage permanent** : (i) reprise automatique horaire ; (ii) chaque obligation a une voie de sortie existante (client paie ; super-admin approuve/rejette un règlement `transferSettlement` ; remise de fonds confirmée/résolue par `partnerOrderActions` ; litige tranché par `adminOrderDisputeCF`/`adminBillingCF`) ; (iii) escalade à 30 jours : le support voit les dossiers `financial_obligation_pending` plus anciens (champ `blockedSince` additif, lecture seule dans `manageAccountDeletionCF`) — aucune suppression forcée d'obligation, aucune levée automatique.

### 4.4 Effet des crédits sous quarantaine
Un crédit (remboursement, règlement) reçu pendant la quarantaine met `wallet ≠ 0` ⇒ `inspect` refuse l'anonymisation (`balance_regularization_required`) : l'argent n'est **jamais** perdu, mais le compte attend une régularisation du support (retrait impossible sous quarantaine). Réserve R6.

### 4.5 Conservation minimale pour la traçabilité (à l'anonymisation)
Conservé : `orders` (montants, statuts, `isPaid`, `paymentMethod`, identifiants techniques) sans champs personnels (déjà le cas) ; `wallet_transactions` ; `transfer_settlements`, `reconciliation_flags`, `order_dispute_decisions`, `audit_logs` ; sur le profil : `wallet`, `isDeleted`, `deletedAt`, `retentionReviewRequired:true` (déjà posé). Ajout additif : `financialSnapshot` `{ordersChecked, obligationsOpen:0, at}` écrit dans l'enregistrement `account_deletions/{uid}` (pas sur le profil) à l'anonymisation, pour prouver qu'aucune obligation n'était ouverte à cet instant.

### 4.6 Fichiers, tests, critères
| Fichier | Modification |
|---|---|
| `functions/accountObligations.js` | **nouveau**, fonction pure + constantes |
| `functions/accountDeletion.js` | `inspect()` : appel au prédicat sur chaque commande lue + 2 requêtes plafonnées ; `blockedSince` |
| `functions/accountDeletionScope.js` | idem pour `readDeletionScope` (rôle `partner`) |
| `functions/manualAccountDeletion.js` | `financialBlocker()` : même prédicat |
| `functions/accountDeletionSupport.js` | exposer `blockedSince`/code (lecture) |
| `functions/test/accountObligations.test.js` | **nouveau** (table de cas par code, exclusions, types inattendus) |
| `functions/test/accountDeletionHardening.test.js`, `manualAccountDeletion.test.js` | cas bloqué/repris/anonymisation refusée |
| `functions/test/accountDeletionObligations.emulator.test.js` | **nouveau** (§8) |
Critères d'acceptation : chaque code de §4.2 bloque quarantaine **et** anonymisation pour les rôles concernés ; reprise automatique prouvée ; aucune requête non bornée ; aucun changement de comportement pour un compte sans obligation ; tests existants inchangés ; 0 modification des collections « Cloud-Function-only ».

## 5. Exceptions de wrapper (spécification)
- **Nouveau** dans `index.js` : `onCallClosing(options, handler)` — même enveloppe que `onCall` **sans** `assertAccountEnabled` ; le gestionnaire reçoit l'appel. Contrat : tout gestionnaire passé à `onCallClosing` **doit** appeler `assertClosureActor` dans sa transaction avant toute écriture (vérifié par un test qui exécute chaque fonction de la liste fermée avec un acteur anonymisé et vérifie le refus).
- **Liste fermée (4)** : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof`. Test de câblage : `index.js` n'emploie `onCallClosing` que pour ces 4 exports.
- `assertAccountEnabled` **reste inchangé** et reste appelé par toutes les autres fonctions.
- Les options (`maxInstances`, `capInstances`, `pilotOnlyInstanceOptions`) sont conservées à l'identique (aucune hausse CPU/instances : quota Cloud Run non confirmé).

## 6. Spécification du lot 2C
### 6.1 Helpers (`functions/accountAdmission.js`, ajouts purs et tests)
- `accountCreditState(profile, hasTombstone)` → `'active' | 'closing' | 'anonymized' | 'absent'` (`profile` absent ⇒ `absent` ; `isDeleted === true` ⇒ `anonymized` ; tombstone ou `isSuspended`/`deletionRequested` ⇒ `closing` ; sinon `active`).
- `assertClosureActor(tx, db, HttpsError, { uid, collection })` : **dans la transaction**, lit `account_tombstones/{uid}` puis `<collection>/{uid}` ; `absent`/`anonymized` ⇒ `permission-denied / ACCOUNT_DELETION_IN_PROGRESS` (même code que le wrapper : aucun changement Flutter) ; `closing`/`active` ⇒ autorise. Elle **ne remplace pas** les contrôles d'association/statut des fonctions.
- `assertBeneficiaryCreditable(tx, db, HttpsError, [{collection, id}])` : lit tombstone + profil de chacun ; `absent` ⇒ `failed-precondition / BENEFICIARY_NOT_FOUND` ; `anonymized` ⇒ `failed-precondition / BENEFICIARY_ACCOUNT_CLOSED` ; `closing`/`active` ⇒ ok. Les lectures sont toutes faites **avant** la première écriture.

### 6.2 `buildPayOrderFromWallet` (`orderActions.js:48-170`) — modifications
Ordre dans l'unique transaction : (1) lecture commande ; (2) contrôles existants (propriétaire, `isPaid`, `amountsVersion`, `driverId`) ; (3) **nouveau** : statut — refus si `status ∈ {cancelled, expired, refunded, failed, rejected}` (`failed-precondition / PAYMENT_ORDER_NOT_PAYABLE`) ; refus si `needsReview === true ∧ reviewReason === 'beneficiary_account_closed'` (revue non levée) ; (4) lectures `clients`, `livreurs`, `pharmacies` **et** `account_tombstones` de chacun ; (5) `assertClosureActor` (payeur) ; (6) `assertBeneficiaryCreditable` (livreur si crédit direct, i.e. `!settlementHold` ; pharmacie si `medAmount > 0`) — **avant** toute écriture ; (7) écritures existantes (débit, crédits, commande) **plus** les journaux ci-dessous.
- **Cas livreur retenu (`settlementHold`)** : aucun crédit livreur ; le contrôle du livreur n'est pas bloquant (le gain reste retenu, règlement administratif).
- **Journaux dans la transaction** (atomicité) : `clients/{uid}/wallet_transactions/pay_order_<orderId>`, `livreurs/{id}/wallet_transactions/earning_pay_order_<orderId>`, `pharmacies/{id}/wallet_transactions/earning_pay_order_<orderId>` via `tx.set` à identifiants déterministes (modèle de `transferSettlement`, `transfer_settlement_<order>_<driver>`). Supprime le risque R11 « argent déplacé sans journal » ; rejeu sans doublon. Même `type`/`amount`/`description`/`orderId`.
- **Audit** : `logAudit` reste après la transaction (écriture best-effort, comportement actuel) ; l'atomicité financière est portée par les journaux ; une perte d'audit est récupérable par `orders.isPaid`/`paidAt`/`paidBy` (champs additifs ajoutés dans la même transaction). Documenté comme limite.
- **Refus D6-a** : l'`HttpsError` annule la transaction (aucun effet) ; le gestionnaire l'intercepte **hors transaction** et écrit, de façon idempotente, `reconciliation_flags/<orderId>_beneficiary_closed` (`type:'beneficiary_account_closed'`, `status:'open'`, ids, montant demandé, `createdAtMs`) et un `logAudit` `status:'denied'`, puis relance l'erreur. La mise en revue `orders.needsReview:true / reviewReason` est posée par une transaction distincte, courte et idempotente (modèle de `recordPickedUpCancelRequest`).
- **Levée de la revue** : nouvelle action `clearBeneficiaryReview` de `adminBillingCF` (super-admin, `requestId` idempotent, justification ≥ 10 caractères, audit), qui remet `needsReview:false` et ferme le flag ; sans elle, toute nouvelle tentative est refusée (verrou ci-dessus).
- **Idempotence / retries** : `isPaid` relu dans la transaction ; contention ⇒ rejeu Firestore ; journaux déterministes ⇒ rejeu sans doublon.
- **Wrapper** : `onCall: (h) => onCallClosing({ maxInstances: 3 }, h)`.

### 6.3 `buildCancelOrder` / `cancelOrderTx` (D6-c, DR1)
- `onCallClosing` ; dans la transaction : `assertClosureActor` (client) avant `cancelOrderTx`. Les contrôles `order.clientId !== uid`, `ORDER_NOT_CANCELLABLE`, `ORDER_PICKED_UP`, `ORDER_IN_PREPARATION` sont **conservés** (l'annulation n'est permise que si le statut l'autorise encore).
- Dans `cancelOrderTx` : lire (avant écritures) le profil du livreur payeur ; si `anonymized` ⇒ DR1 (crédit omis, flag ouvert, `commissionStatus` inchangé) ; si `absent` : comportement actuel (`payerSnap.exists`), flag ouvert. Le client est remboursé normalement.
- Aucune nouvelle commande ; aucune levée de quarantaine.

### 6.4 `buildDeliverOrder` et variante avec preuve (D6-c, DR2)
- `deliverOrderCF` et `confirmOrderDeliveryWithProof` en `onCallClosing` ; `assertClosureActor` (livreur, collection `livreurs`) **avant** les écritures ; l'association `order.driverId !== uid` et les statuts `accepted/picked_up` sont **conservés**. `adminConfirmDeliveryCF` inchangé (mode admin, acteur = super-admin ; le livreur de référence est lu et contrôlé comme `uid`).
- Partenaire à créditer (restaurant/pharmacie/boulangerie, `isPaid === true`) : `accountCreditState` ; `anonymized`/`absent` ⇒ refus `BENEFICIARY_ACCOUNT_CLOSED` (DR2), sinon crédit.
- Le crédit du livreur lui-même (acteur) n'est pas refusé : acteur `closing` ⇒ crédité (restitution), ce qui bloque son anonymisation tant que le solde ≠ 0 (R6).

### 6.5 Autres chemins de crédit (D1/D2) — sous-lot D
| Chemin | Règle | Fichiers |
|---|---|---|
| Compensation de retrait FAILED (`feexpayPayments.js` `applyPayoutStatus` l. ~427, `compensateFailedWithdrawal` l. ~715) | `closing` ⇒ crédit normal + événement de sécurité ; `anonymized` ⇒ aucun crédit, `needsReview:true`, `anomaly:'profile_anonymized'` (D1) | `feexpayPayments.js` |
| `transferSettlement` approve (wallet) | `anonymized`/`absent` pour un livreur crédité ⇒ approbation refusée en entier (aucun crédit partiel), code explicite ; `closing` ⇒ ok (D2) | `transferSettlement.js` |
| `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds` | cible `anonymized`/`absent` ⇒ refus explicite et tracé ; `closing` ⇒ ok (D2) | modules admin |
Chaque garde utilise `assertBeneficiaryCreditable` (lectures avant écritures). Les crédits admin sont atomiques par cible ; un lot multi-cibles est refusé en entier.

### 6.6 Flutter
`lib/screens/client/suivi_commande.dart` : afficher un message dédié pour `BENEFICIARY_ACCOUNT_CLOSED` (« Ce paiement est suspendu : le support AZ Express va le traiter. Rien n'a été débité. ») et `PAYMENT_ORDER_NOT_PAYABLE` ; la détection par texte reste fragile (réserve existante, R3). Aucun changement requis pour `ACCOUNT_DELETION_IN_PROGRESS`.

## 7. Atomicité financière (synthèse)
| Élément | Aujourd'hui | Spécifié |
|---|---|---|
| Débit client + crédits + `isPaid` | une transaction ✔ | inchangé ✔ |
| Contrôles de statut de compte | wrapper (appelant, hors transaction) ; bénéficiaires **jamais** | acteur **et** bénéficiaires **en transaction**, avant écritures |
| `wallet_transactions` | `.add()` après transaction (non atomique) | `tx.set` à identifiants déterministes dans la transaction |
| `logAudit` | après transaction (best-effort) | inchangé ; reconstructible via `paidAt/paidBy` |
| Trace d'un refus D6-a | inexistante | flag + `needsReview` hors transaction, idempotents |
| Retry / concurrence | rejeu Firestore | idem ; tombstone et profil bénéficiaire lus en transaction ⇒ une anonymisation concurrente provoque un conflit et un rejeu **(à démontrer sur émulateur, [ND] en production)** |

## 8. Matrice de tests
Fixture commune : `c1 {wallet:5000}`, `d1 {wallet:0}`, `p1 {wallet:0}`, `o1 {clientId:c1, driverId:d1, pharmacieId:p1, status:'delivered', budget:1000, isPaid:false, paymentMethod:'wallet', type:'pharmacie'}` ; appel `payOrderFromWalletCF(o1, medicineAmount:500)` ⇒ total 1500. **U** = unitaire (faux Firestore) · **E** = émulateur `demo-*` isolé · **R** = nécessite un environnement réel (préproduction).
| # | Scénario | Attendu (soldes / documents) | Niveau |
|---|---|---|---|
| 1 | Client actif | c1 3500, d1 1000, p1 500 ; `o1.isPaid:true` ; 3 journaux déterministes ; audit | U, E |
| 2 | Client en quarantaine : **nouvelle** commande (`createOrderFromQuoteCF`, `payBoutiqueOrderCF`) | refus ; aucun solde/commande modifié (existant 2B) | U, E (existant) |
| 3 | Client en quarantaine : commande engagée payable (D6-b) | comme #1 ; tombstone et `isSuspended` **intacts** | U, E |
| 4 | Client `isDeleted` (jeton encore valide) | refus `ACCOUNT_DELETION_IN_PROGRESS` ; c1 5000 ; `o1.isPaid:false` | U, E |
| 5 | Livreur `isDeleted` | refus `BENEFICIARY_ACCOUNT_CLOSED` ; c1 5000, d1 0, p1 0 ; `o1.isPaid:false` ; flag ouvert + `needsReview` | U, E |
| 6 | Pharmacie `isDeleted` | idem #5 | U, E |
| 7 | Livreur ou pharmacie sans document | refus `BENEFICIARY_NOT_FOUND` **avant écriture** ; soldes inchangés | U, E |
| 8 | Annulation légitime sous quarantaine (`status:'accepted'`, `isPaid:true`, wallet) | c1 +remboursement ; commission rendue au livreur payeur ; `status:'cancelled'` ; tombstone intact | U, E |
| 9 | Annulation d'une commande non annulable (`delivered`/`picked_up`) | `failed-precondition` / demande post-récupération ; aucun solde modifié | U |
| 10 | Livraison par le livreur associé en quarantaine | `status:'delivered'` ; crédits selon `isPaid` ; livreur libéré ; tombstone intact | U, E |
| 11 | Livraison par un livreur non associé | `permission-denied` ; aucune écriture | U |
| 12 | Commande déjà annulée | paiement : `PAYMENT_ORDER_NOT_PAYABLE` ; livraison : `failed-precondition` ; aucun solde modifié | U |
| 13 | Commande déjà payée | `Commande déjà payée` ; soldes inchangés ; aucun journal en double | U, E |
| 14 | Deux paiements simultanés | un seul débit/crédit/journal ; l'autre échoue `déjà payée` ou rejoue | **E** (le faux Firestore ne modélise pas la contention) |
| 15 | Paiement concurrent avec tombstone du payeur | paiement abouti (restitution) ; wallet payeur débité ; invariants conservés | **E** |
| 16 | Anonymisation du bénéficiaire concurrente avec le règlement | soit paiement complet avant `isDeleted`, soit refus D6-a sans effet ; **jamais** crédit sur `isDeleted` ; boucle d'ordonnancements (modèle 2B : `before/after/during/jitter`) | **E** |
| 17 | Compensation de retrait sur compte en quarantaine | wallet + montant ; événement de sécurité | U |
| 18 | Compensation sur compte anonymisé | aucun crédit ; `needsReview:true`, `anomaly:'profile_anonymized'` | U |
| 19 | Crédit administrateur (`adminBilling`/litige/`transferSettlement`) sur quarantaine | crédit effectué ; tombstone intact | U |
| 20 | Crédit administrateur sur `isDeleted` | refus explicite ; solde inchangé ; trace | U |
| 21 | Suppression avec obligation non réglée (chaque code de §4.2, rôles client/livreur/partenaire) | pas de tombstone (avant) ou tombstone conservé sans `isDeleted` (pendant) ; `blocked` + code ; aucun nettoyage | U, E |
| 22 | Reprise après règlement de l'obligation | `drain` suivant : quarantaine puis anonymisation ; `financialSnapshot` écrit | U, E |
| 23 | Câblage : `onCallClosing` limité aux 4 exports ; acteur anonymisé refusé pour chacun | échec si une cinquième fonction l'utilise | U |
| 24 | Rejeu du même paiement après arrêt simulé entre transaction et audit | état financier cohérent (journaux dans la transaction) | U |
**Validations impossibles sans environnement réel [R]** : comportement des verrous Firestore en production ; durée réelle de validité d'un jeton d'un compte supprimé ; messages Flutter sur appareil ; effet d'un crédit sur profil anonymisé réel ; tout ce qui dépend du quota Cloud Run. **Aucun** test sur production.

## 9. Ordre d'exécution
| Étape | Contenu | Dépend de | Motif |
|---|---|---|---|
| **0** | Relecture et autorisation humaine de cette spécification (dont DR1-DR3) | — | — |
| **1** | **2D-1** `accountObligations.js` + tests purs (sans branchement) | — | aucun risque comportemental |
| **2** | **2D-2** branchement dans `inspect`, `readDeletionScope`, `financialBlocker`, `blockedSince` ; tests + émulateur (#21, #22) | 1 | ferme la fenêtre d'anonymisation prématurée (N1/N2) **avant** tout assouplissement du wrapper |
| **3** | **2C-A** helpers (`accountCreditState`, `assertClosureActor`, `assertBeneficiaryCreditable`) + tests purs | — (peut précéder 2) | aucune exposition |
| **4** | **2C-B** `payOrderFromWalletCF` (garde bénéficiaires, statut, journaux, trace D6-a, `clearBeneficiaryReview`) + `onCallClosing` pour cette seule fonction ; tests #1-#7, #12-#16, #24 | 2, 3 | l'exception de wrapper n'est introduite qu'**avec** ses gardes |
| **5** | **2C-C** `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof` (D6-c, DR1, DR2) ; tests #8-#11, #23 | 4 | réutilise `onCallClosing` |
| **6** | **2C-D** chemins de crédit (D1/D2) : compensation, `transferSettlement`, admin ; tests #17-#20 | 3 | indépendant de 4-5 mais après 2D |
| **7** | Messages Flutter | 4 | — |
Chaque étape = un commit local distinct, après revue, sans mélange. 2C peut être implémenté **après** 2D sans réintroduire de risque : 2D supprime la population d'obligations orphelines qui rendait les exceptions de wrapper nécessaires en pratique ; 2C-A à 2C-D n'ajoutent que des refus supplémentaires et une exception à liste fermée.
**À ne pas mélanger** : `setPharmaciePassword` (P3), Commit 3 E-Kbine (`ekbineOrders.js`, D3), `professionalSubscriptions.js`, outil `held_for_review`, scripts de déploiement, `web/legal`, `restaurantV2Preprod.test.js`. `held_for_review` reste **obligatoire avant l'activation réelle de FeexPay**. **Quota Cloud Run non confirmé : aucun déploiement.**

## 10. Manifeste technique (vérifié sur le code actuel)
| Lot | Fichiers à modifier | Fonctions | Tests à créer / adapter | Critères d'acceptation |
|---|---|---|---|---|
| **2D** | `accountObligations.js` (new), `accountDeletion.js` (`inspect`), `accountDeletionScope.js` (`readDeletionScope`), `manualAccountDeletion.js` (`financialBlocker`), `accountDeletionSupport.js` | prédicat, 3 inspecteurs | `accountObligations.test.js` (new), `accountDeletionHardening.test.js`, `manualAccountDeletion.test.js`, `accountDeletionObligations.emulator.test.js` (new) | §4.6 |
| **2C-A** | `accountAdmission.js` | `accountCreditState`, `assertClosureActor`, `assertBeneficiaryCreditable` | `accountAdmission.test.js`, `accountQuarantineGuards.test.js` | helpers purs, erreurs stables |
| **2C-B** | `orderActions.js` (`buildPayOrderFromWallet` uniquement), `index.js` (`onCallClosing`, câblage `payOrderFromWalletCF`), `adminBilling.js` (`clearBeneficiaryReview`) | `buildPayOrderFromWallet`, wrapper | `orderActions.test.js` (adapter les attentes de journaux), `payOrderClosure.test.js` (new), `payOrderClosure.emulator.test.js` (new) | #1-#7, #12-#16, #24 |
| **2C-C** | `orderActions.js` (`cancelOrderTx`, `buildCancelOrder`, `buildDeliverOrder`), `deliveryProofs.js` (`buildDeliverOrderWithProof` si la garde y vit), `index.js` (câblage) | annulation/livraison | `orderActions.test.js`, `orderClosure.test.js` (new), `orderClosure.emulator.test.js` (new) | #8-#11, #23 |
| **2C-D** | `feexpayPayments.js`, `transferSettlement.js`, `adminBilling.js`, `adminOrderDisputes.js`, `adminOrderRefunds.js` | compensation, règlement, crédits admin | tests existants + cas D1/D2 | #17-#20 |
| Flutter | `suivi_commande.dart` | message d'erreur | test widget/contrat | message affiché, aucun débit |
Dépendances : 2C-B/C/D dépendent de 2C-A ; 2D indépendant. Risques résiduels : §11.

## 11. Risques et réserves
| # | Risque / réserve | Traitement |
|---|---|---|
| R1 | Contention et verrous Firestore en production non démontrés ; émulateur ≠ production ; `Transaction is invalid or closed` (INVALID_ARGUMENT) observé en émulateur (rejeu non automatique) | fail-closed sans écriture ; test d'ordonnancement ; validation en préproduction |
| R2 | Journaux déterministes dans la transaction modifient des tests existants (`orderActions.test.js`) et le comportement du rejeu | adapter les tests ; valider l'absence de collision d'identifiants |
| R3 | Flutter lit encore le texte d'erreur ; flux devis inactif ; jamais testé sur appareil | codes explicites + message dédié ; test réel requis |
| R4 | Un livreur en quarantaine ne peut ni récupérer ni libérer une commande `accepted` (progression et transfert exclus de l'exception) | annulation par le client ou action administrative ; cas rare (le moteur refuse la quarantaine d'un livreur avec mission) |
| R5 | DR1-DR3 sont des règles dérivées | à relire lors de l'autorisation d'implémentation |
| R6 | Un crédit sous quarantaine immobilise le compte (`balance_regularization_required`) sans voie de retrait | régularisation par le support ; hors périmètre |
| R7 | Jeton d'un compte supprimé valide environ une heure | garde `isDeleted` en transaction (déjà spécifiée) |
| R8 | `inspect()` ne gère que `client`/`livreur` ; autres rôles bloqués ou via `readDeletionScope` seulement si `partnerInventoryVersion === 1` | 2D applique le prédicat aux trois inspecteurs ; ne pas élargir les rôles |
| R9 | Calibrage du prédicat (faux positifs bloquants, par ex. `cashRemittance` ancien) | table de cas + essais sur comptes synthétiques en préproduction avant toute activation |
| R10 | `held_for_review` : outil absent | obligatoire avant l'activation réelle de FeexPay |
| R11 | Quota Cloud Run non confirmé | aucun déploiement ; aucune hausse CPU/instances dans ces lots |
| R12 | Audit post-transaction best-effort | reconstructible, documenté |
**Limites de l'analyse** : lecture du code HEAD des trois inspecteurs, de `buildPayOrderFromWallet`, `buildCancelOrder`/`cancelOrderTx`, du début de `buildDeliverOrder`, du câblage `index.js` des callables concernés et des champs de règlement ; `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds`, la fin de `buildDeliverOrder`, `deliveryProofs.js` (`buildDeliverOrderWithProof`) et `partnerOrderActions` n'ont pas été relus ligne à ligne dans cette mission (les points les concernant sont à confirmer au début de l'implémentation correspondante). Aucun test exécuté ; aucune donnée de production.

## 12. État Git
HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` · index vide · aucun nouveau commit · aucun push · aucun déploiement · worktree préservé (les 89 entrées d'avant + ce rapport).

## Verdict
**LOTS 2C ET 2D SPÉCIFIÉS — PRÊTS POUR IMPLÉMENTATION**
Les décisions D6-a/b/c sont intégrées sans être rouvertes ; l'ordre est 2D (fenêtre d'anonymisation) puis 2C (A→D) ; la seule marge restante est la relecture de trois règles dérivées (DR1-DR3, §1) et la vérification de quelques modules non relus (§11), à faire au démarrage de l'implémentation concernée. Aucune modification de code, aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
