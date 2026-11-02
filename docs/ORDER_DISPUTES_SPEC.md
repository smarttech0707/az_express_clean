# Litiges financiers après récupération du colis — spécification (variante D)

Statut : **VALIDÉE le 2026-10-30, implémentée localement, NON déployée.** Les quatre options de remboursement
(A shopping, B frais, C 50 % des frais, D total), la résolution sans clôture et la confirmation administrative de
livraison existent dans `functions/adminOrderDisputes.js`, `functions/orderActions.js` (mode `adminConfirm`) et les
écrans `lib/screens/admin/admin_disputes_page.dart` / `admin_stuck_alerts_page.dart` (non rattachés au menu).

Périmètre : livraisons ordinaires (`orders`, hors Marketplace/Boutique, qui restent traités par `adminBilling`).
Variante D : le remboursement, total ou partiel, est décidé par le **super-administrateur**.

## 1. Principes non négociables

1. Aucun remboursement automatique après `picked_up`. Le client ne peut qu'ouvrir une demande
   (`orders.cancelRequestAfterPickup`), jamais déclencher un mouvement d'argent.
2. Remboursement client **≤ montant réellement encaissé** sur son wallet pour cette commande (`paidFromWallet`).
3. Pas de saisie libre : le montant partiel est choisi parmi des plafonds calculés par le serveur (§4).
4. Toute décision : super-admin, justification ≥ 10 caractères, `requestId` idempotent, transaction, `audit_logs`.
5. Aucune écriture wallet depuis Flutter : tout passe par la Cloud Function (Admin SDK).

## 2. Montants réellement encaissés

| Cas | Encaissé |
|---|---|
| Wallet, livraison/course | `budget` (ou `totalAmount` si montants explicites) |
| Wallet + `shoppingBudget` (achat pour compte) | `budget + shoppingBudget` (règle `walletDebitMatchesPaidOrder`) |
| Cash | 0 : rien à rembourser sur wallet, litige = hors système |
| Pharmacie wallet non payée (`isPaid:false`), course boutique | 0 |

La commission livreur (100 FCFA si budget < 1000, sinon 200) est prélevée **une fois, à l'acceptation**, sur le wallet
du livreur. Elle n'est pas un montant payé par le client.

## 3. Conditions

**Remboursement total** (annulation exceptionnelle, **implémenté**) : colis non remis ou perdu, livreur injoignable,
preuve de non-livraison, aucune livraison constatée. Effets : statut `cancelled`, client crédité de l'encaissé
(budget + shoppingBudget), commission rendue **au payeur d'origine**, une seule fois (`commission_<orderId>_<driverId>`),
livreur non payé.

**Remboursement partiel** (**à valider**) : livraison réalisée mais défaillante (article manquant, achat non conforme,
retard avéré). Le client est remboursé d'une part, le livreur reçoit le reste selon la règle choisie (§4).

**Refus** : cash ; commande non `picked_up` (autre circuit) ; Marketplace/Boutique (→ `adminBilling`) ; déjà
décidée (rejeu idempotent) ; plafond dépassé ; justification absente ; demande de non-super-admin.

## 4. Remboursement partiel — plafonds proposés (aucune saisie libre)

Le serveur calcule `paid`, `fee` (= `budget`, frais de livraison) et `shopping` (= `shoppingBudget`) puis ne propose
que ces options :

| Option | Client remboursé | Livreur crédité |
|---|---|---|
| `refundShopping` | `shopping` | `fee` |
| `refundFee` | `fee` | `shopping` |
| `refundHalfFee` | `fee / 2` arrondi inférieur | `shopping + fee − fee/2` |
| `refundAll` | `paid` (= annulation exceptionnelle) | 0 |

Invariant (A/B/C) : `clientRefund + remboursement des achats avancés + gain livreur = paid`, `clientRefund ≤ paid`, aucun solde négatif, aucun centime créé ni perdu.
Un montant arbitraire n'est pas accepté ; une option hors liste est rejetée.

## 5. Traitement par composante

- **shoppingBudget** : argent confié pour acheter. Inclus dans l'encaissé. Il est remboursé (annulation, `refundShopping`)
  ou versé au livreur selon l'option, jamais les deux.
- **Commissions** : annulation totale → rendue au payeur d'origine (une fois). Partiel → conservée (la livraison a eu lieu)
  et **aucune seconde commission** n'est prélevée.
- **Paiement du livreur** : annulation totale → rien. Partiel → crédit = encaissé − remboursement client, via la règle de
  livraison normale (une seule fois, §7).
- **Cash vs wallet** : wallet = mouvements ci-dessus. Cash = aucun mouvement client ; la commission seule peut être rendue
  au livreur si annulation totale ; le règlement du cash reste hors système.
- **Vendeurs/partenaires** : pharmacie/restaurant/boulangerie : si la part vendeur n'est pas encore versée (`sellerShare`),
  elle est retenue au prorata du remboursement ; si déjà versée, **aucune reprise automatique** : alerte admin. Marketplace/
  Boutique : hors périmètre, `adminBilling`.

## 6. Concurrence et idempotence

- Une transaction unique : lecture de la décision `order_dispute_decisions/{sha256(orderId|requestId)}` (rejeu = même
  résultat, aucun nouveau mouvement), lecture de la commande, puis écritures. Lecture avant écriture.
- Garde de statut dans la transaction : seule une commande `picked_up` est décidable ; une seconde décision concurrente
  échoue en `failed-precondition` (statut déjà modifié).
- Rate limit `admin_order_dispute_decide` (60 / 600 s).

## 7. Distinction : résolution vs confirmation administrative de livraison

| | Résolution (implémentée) | Confirmation de livraison (non implémentée) |
|---|---|---|
| Effet | Demande classée, **commande inchangée** (`picked_up`) | Statut `delivered`, livreur payé |
| Argent | Aucun | Crédit livreur selon règles normales |
| Permission | `commandes` | super-admin |
| Prérequis | Litige ouvert | Livraison **réellement constatée** (preuve QR/PIN, appel client, trace admin) |

Confirmation (option i retenue) — impacts à valider avant implémentation :
- Réutiliser le cœur de `deliverOrderCF` (une seule voie de crédit livreur) plutôt que dupliquer la logique.
- Garde anti double crédit : refus si `deliveredAt` / crédit déjà tracé ; la commission n'est **pas** reprélevée.
- Transaction, journal `audit_logs`, `adminReview.action = 'disputeConfirmDelivery'`, `requestId` idempotent.
- Impact notation livreur (`driverRatings`) : la note ne se déclenche que si le client note ; aucun effet automatique.
- Impact stats/BI : la commande compte comme livrée avec `confirmedBy: 'admin'`.

## 8. Journal d'audit

`logAudit({ action:'admin_order_dispute', targetId:orderId, userId:admin, status, amount, metadata:{ decision,
justification, financialTreatment, clientRefund, driverRefund } })` ; erreurs journalisées en `status:'error'`.
Champs commande : `disputeDecision`, `adminReview`, `cancelRequestAfterPickup.status`.

## 9. À valider

1. Les 4 options de remboursement partiel (§4) sont-elles les bonnes ?
2. Commission conservée en partiel, rendue en total : confirmé ?
3. Part vendeur déjà versée : alerte seulement (pas de reprise automatique) ?
4. Autoriser la confirmation administrative de livraison, par le super-admin seul ?
5. Interface admin (litiges + alertes) : à construire (l'action serveur `listAlerts` est prête).

## 10. Décisions du propriétaire (2026-10-30) et état d'implémentation

- Options A/B/C/D : montants **calculés côté serveur** (`planRefund`), jamais saisis ; super-admin seul ; invariants testés
  (remboursé + livreur = payé ; remboursé ≤ payé ; entiers).
- Vérifications avant tout remboursement : livreur déjà payé / gain retenu (refus), commission (conservée en partiel,
  rendue au payeur d'origine en total), vendeur (partiel refusé ; en total, wallet vendeur **jamais** débité, signalement
  `reconciliation_flags/{orderId}_seller_{décision}`), course transférée (refus partiel).
- Budget d'achat : situation à déclarer (`shoppingContext` : `not_purchased`, `purchased_returned`, `purchased_delivered`,
  `purchased_unreturned`). Si le budget est dépensé (remis au client / non retourné), A et D sont refusés sauf
  `justifiedSpentRefund: true` avec justification ≥ 30 caractères ; B et C restent possibles. Le serveur ne peut pas
  vérifier les achats lui-même (aucune donnée) : la déclaration est tracée dans `disputeDecision` et l'audit.
- Confirmation administrative de livraison : `adminConfirmDeliveryCF` = `buildDeliverOrder({ adminConfirm: true })`, super-admin
  seul, statut `picked_up` exigé, hors course transférée, justification ≥ 10 caractères + preuve (`client_confirmed`,
  `driver_proof`, `phone_verified`, `other_justified`), `requestId` idempotent, même crédit livreur que `deliverOrderCF`,
  aucune nouvelle commission. Trace : `orders.adminDeliveryConfirmation`, audit `admin_confirm_delivery`.
- Écrans admin : « Litiges de livraison » (liste, dossier, décisions, rapprochements) et « Commandes bloquées » (alertes).
  Ils n'écrivent rien dans Firestore et ne sont **pas** ajoutés à `admin_menu.dart` avant déploiement vérifié.

## 11. Audit financier A/B/C/D (exemple du propriétaire : frais 500, achat 3 000, payé 3 500)

Exécuté avec le vrai code sur un faux Firestore (client 10 000 après paiement, livreur 900 après commission de 100).
« Séquestre » = les 3 500 FCFA débités au client et pas encore versés à personne (le livreur n'est crédité qu'à la livraison).

| Contexte d'achat déclaré | Option | Client | Livreur | Séquestre sorti | Commission AZ |
|---|---|---|---|---|---|
| non acheté / retourné | A rembourser l'achat | +3 000 | +500 | 3 500 / 3 500 | 100 conservée |
| non acheté / retourné | B rembourser les frais | +500 | **+3 000** | 3 500 / 3 500 | 100 conservée |
| non acheté / retourné | C 50 % des frais | +250 | **+3 250** | 3 500 / 3 500 | 100 conservée |
| non acheté / retourné | D total | +3 500 | +100 (commission rendue) | 3 500 / 3 500 | rendue |
| acheté et remis / non retourné | A | REFUSÉ sans décision justifiée (30 car.) | | | |
| acheté et remis / non retourné | B | +500 | +3 000 (remboursement de l'achat) | 3 500 / 3 500 | 100 conservée |
| acheté et remis / non retourné | C | +250 | +3 250 | 3 500 / 3 500 | 100 conservée |
| acheté et remis / non retourné | D | REFUSÉ sans décision justifiée | | | |

Conservation : dans tous les cas, client + livreur (hors commission rendue) = 3 500, sans création ni perte d'argent.

### Correction B/C appliquée (2026-10-30, validée dans son principe par le propriétaire)

Le budget d'achat (`shoppingBudget`) **n'est jamais une rémunération du livreur**. Cinq postes distincts :
(1) remboursement client (frais / achat), (2) remboursement des achats réellement avancés par le livreur,
(3) rémunération du livreur, (4) commission AZ, (5) sommes déjà versées ou retenues (→ décision refusée, manuelle).
Aucune nouvelle règle de rémunération : (3) = uniquement la part des frais non remboursée (A : 100 % des frais ; C : l'autre moitié).

Exemple : frais 500, achat 3 000, payé 3 500, commission AZ 100 (déjà prélevée au livreur à l'acceptation, séquestre = 3 500).

| Situation du budget | Option | Client | Livreur : achats avancés | Livreur : gain | Commission AZ |
|---|---|---|---|---|---|
| non acheté / retourné | A | +3 000 | 0 | +500 | 100 conservée |
| non acheté / retourné | B | +3 500 | 0 | 0 | 100 conservée |
| non acheté / retourné | C | +3 250 | 0 | +250 | 100 conservée |
| non acheté / retourné | D | +3 500 | 0 | 0 (+100 commission rendue) | rendue |
| dépensé (remis / non retourné), livreur a avancé | A (décision justifiée ≥ 30 car.) | +3 000 | 0 | +500 | conservée ; **signalement** `driver_advance_unreimbursed` 3 000 |
| dépensé, livreur a avancé | B | +500 | +3 000 | 0 | conservée |
| dépensé, livreur a avancé | C | +250 | +3 000 | +250 | conservée |
| dépensé, livreur a avancé | D (décision justifiée) | +3 500 | 0 | 0 (+100 commission rendue) | rendue ; signalement avance 3 000 |
| dépensé, avance NON déclarée | B, C | **REFUSÉ** (aucune règle de versement inventée) | | | |
| dépensé | A, D sans décision justifiée | **REFUSÉ** | | | |

Garde-fous : un seul versement par décision (idempotence `order_dispute_decisions`), `clientRefund + remboursement achats + gain = payé`
pour A/B/C, jamais plus que le payé, livreur déjà payé / gain retenu → refus, commission déjà remboursée → jamais remboursée deux fois
(partiel : 0 conservée ; D : rien de plus rendu), cash / non payé → aucun remboursement partiel.
Les écritures wallet du livreur sont séparées (`reimbursement` pour les achats avancés, `earning` pour le gain).
Signalements `reconciliation_flags/{orderId}_seller_{16 car. de la décision}` et `{orderId}_driver_advance_{16 car.}` : une décision
ne peut plus écraser le signalement d'une autre, le rejeu de la même décision retombe sur le même document.

### Commission non tracée (corrigé localement le 2026-10-30)

Une commission n'est rendue que si l'ordre porte la preuve de son prélèvement : `commissionStatus === 'charged'`, payeur valide et montant entier
(`commissionAmount`). Sans cette preuve, `cancelOrderTx` (annulation client, expiration, outil AZ IA, décision D) **ne crédite plus le livreur** : le montant
n'est jamais déduit du barème théorique. L'annulation et le remboursement du client se font normalement ; un signalement idempotent
`reconciliation_flags/{orderId}_commission_untraced` (type `commission_untraced`) est créé pour que le super-admin vérifie le prélèvement.
Idempotence inchangée (commande close, `commissionStatus: 'refunded'` posé seulement quand un montant tracé est rendu).
`driverRelease.js` (libération avant récupération) suit la même règle : crédit uniquement si l'ordre est tracé OU si la transaction de wallet `commission_<commande>_<livreur>` (type `commission`, même commande, montant entier > 0) prouve le prélèvement — le montant rendu est alors celui de cette transaction, jamais le barème. Sans preuve : libération normale, aucun crédit, signalement `{orderId}_commission_untraced_{livreur}`.

### Avances du livreur à régler (A et D sur achat dépensé)

État actuel : le montant avancé est conservé (`reconciliation_flags/{orderId}_driver_advance_{décision}`, type `driver_advance_unreimbursed`, `amount`, `driverId`,
`status: open`) et affiché en tête de l'écran « Rapprochements » du super-admin. **Aucune compensation automatique n'existe.** La commande est close :
une seconde décision de litige est impossible, donc au plus un signalement par commande.

Proposition de règlement (NON implémentée, à valider) — action `settleDriverAdvance` d'`adminOrderDisputeCF`, super-admin seul :

1. Entrées : `flagId`, `requestId` (idempotence), `mode` ∈ { `pay` (AZ rembourse le livreur), `waive` (aucun versement, motif écrit) }, justification ≥ 30 caractères,
   référence de preuve (reçu, photo, appel).
2. Une seule transaction : lire le signalement (doit être `open` et de type `driver_advance_unreimbursed`), le comparer à `orders.disputeDecision`
   (`advancedBy = driver_own_funds`, montant identique), lire le wallet du livreur ; puis passer le signalement à `settled`
   (`settledBy`, `settledAtMs`, `settlementMode`, `settlementRequestId`) **et** créditer le livreur dans la même transaction.
3. Anti double compensation : la transition `open → settled` du signalement fait office de verrou (une seconde transaction concurrente relit `settled` et refuse) ;
   document d'idempotence `order_dispute_decisions/{sha256(flagId|requestId)}` ; marqueur `orders.driverAdvanceSettled` ; montant plafonné à `flag.amount` (jamais saisi).
4. Écritures : `wallet_transactions` du livreur (`reimbursement`), `audit_logs`. Le livreur est notifié.
5. **Décision à prendre par le propriétaire avant tout développement** : qui supporte la charge (AZ sur ses fonds propres, ou récupération auprès du client/vendeur par une
   procédure séparée) et comment elle s'inscrit dans le Grand Livre AZ (compte de charges ou `config/az_wallet`). Sans cette décision, aucune écriture de crédit n'est créée.

### Règle comptable des avances (PROPOSITION — rien n'est implémenté, aucun débit automatique)

Le signalement `driver_advance_unreimbursed` classe l'avance dans l'une de quatre catégories, décidée par le super-admin (jamais automatiquement) :

| Catégorie | Quand | Écriture comptable | Mouvement de wallet |
|---|---|---|---|
| 1. Charge supportée par AZ Express | Litige tranché en faveur du client, aucun tiers fautif identifié (A/D justifié) | Charge « avances livreurs non recouvrables » ; le signalement passe à `settled` (mode `az_charge`) | Crédit du livreur par AZ (futur `settleDriverAdvance`) |
| 2. Créance sur le client | Le client a reçu les produits ET a obtenu le remboursement (fraude/erreur du client) | Créance « clients — avances à recouvrer » ouverte, signalement `settled` (mode `client_receivable`) | Crédit du livreur par AZ ; **aucun débit du client** : recouvrement séparé, autorisé au cas par cas |
| 3. Créance sur le vendeur | Produit non conforme / non livré par le vendeur | Créance « vendeurs — avances à recouvrer » (mode `seller_receivable`) | Crédit du livreur par AZ ; **aucun débit du vendeur** : recouvrement séparé, autorisé au cas par cas |
| 4. Décision manuelle | Preuves contradictoires, montant contesté, plusieurs responsables | Signalement maintenu `open` (ou `waived` avec motif écrit, sans versement) | Aucun |

Règles communes : montant plafonné à celui du signalement, une seule issue par signalement (`open → settled|waived`, verrou transactionnel), justification écrite et référence de preuve,
`audit_logs`, aucune écriture sur le wallet du client ou du vendeur. Les créances sont des écritures de suivi (collection serveur seul), pas des débits.
**À valider par le propriétaire avant tout développement** : intitulés comptables, qui peut classer en catégorie 2/3, seuil au-delà duquel la catégorie 1 exige une seconde validation.

### Grand livre de l'option D (contrôle du 2026-10-30 — aucune anomalie, code inchangé)

Constat dans le code : la commission quitte le wallet du livreur **à l'acceptation** (`commissionStatus: charged`, transaction `commission`), mais le **revenu AZ n'est reconnu qu'à la livraison**
(`commissions` + `config/az_wallet.totalCommissions`, `orderActions.js`) ou, pour un litige partiel, à la clôture (`commissionSource: traced_dispute_partial`).
Entre les deux, les 100 FCFA sont une commission « en attente » (ni dans un wallet, ni dans le revenu reconnu). Rendre la commission en D la remet donc dans le wallet du livreur
sans aucune écriture de revenu à annuler (aucune n'avait été passée). La somme des seuls wallets augmente de 100 : la somme du système, non.

Exemple complet (frais 500, achat 3 000, commission 100, mesuré avec le vrai code) :

| | Client | Livreur | Séquestre | Commission en attente | Revenu AZ reconnu | **Total** |
|---|---|---|---|---|---|---|
| Après paiement et acceptation | 10 000 | 900 | 3 500 | 100 | 0 | **14 500** |
| A (achat non dépensé) | 13 000 | 1 400 | 0 | 0 | 100 | 14 500 |
| B | 13 500 | 900 | 0 | 0 | 100 | 14 500 |
| C | 13 250 | 1 150 | 0 | 0 | 100 | 14 500 |
| D (annulation, commission rendue) | 13 500 | 1 000 | 0 | 0 | 0 | 14 500 |

Aucune somme n'est comptée deux fois : en D, la commission passe de « en attente » à wallet du livreur (+100 wallets, −100 en attente) ; en A/B/C, de « en attente » à revenu reconnu.

### Catégories comptables des avances (VALIDÉES par le propriétaire le 2026-10-31 — settleDriverAdvance NON développé)

Intitulés retenus : (1) **Charge exceptionnelle AZ Express** ; (2) **Créance éventuelle sur le client** ; (3) **Créance éventuelle sur le vendeur** ; (4) **Litige en attente de décision**.
Aucun débit automatique du client ou du vendeur : une créance est une écriture de suivi, son recouvrement est autorisé séparément. Aucune action n'est codée.

### Ordre de preuve de la commission (cancelOrderTx et driverRelease, aligné le 2026-10-31)

1. Trace valide sur la commande (`commissionStatus: charged`, payeur, `commissionAmount` entier) → montant tracé, rendu au payeur d'origine.
2. À défaut (commande sans `commissionStatus`) : transaction `livreurs/{livreur}/wallet_transactions/commission_{commande}_{livreur}` de type `commission`, même commande, montant entier > 0.
3. Le montant rendu est celui réellement prélevé (jamais le barème).
4. Idempotence : `commissionStatus: refunded` posé dans la même transaction ; une commande close ne se rejoue pas.
5. Aucune preuve : aucun crédit, signalement `reconciliation_flags/{commande}_commission_untraced` (annulation / litige D) ou `..._{livreur}` (libération).
