# Facturation et rémunération des livraisons Marketplace / Boutique

Statut : **développé et testé en local, non déployé.**

## Décision métier
Le client paie séparément les produits et la livraison. Exemple : produits 5 000 + livraison 500 = 5 500.
Vendeur 5 000 (0 % de commission), commission AZ 100 (prélevée une fois, à l'acceptation, sur les frais),
gain net livreur 400. Barème de livraison inchangé : **Boutique fixe 500 FCFA**, **Marketplace = barème
`tarifService` existant**. Les transferts entre livreurs restent refusés pour ces commandes (`PARTNER_ORDER_REVIEW`).

## Principe de sécurité : jamais plus que le montant accepté
Une ancienne application Boutique affiche le prix des produits seul. Le serveur ne la facture donc jamais davantage.
- La nouvelle application envoie `acceptedTotal` (le total affiché) à `payBoutiqueOrderCF` / `payBoutiqueOrderCashCF`.
  Le serveur recalcule le total et refuse tout écart, dans les deux sens : `MONTANT_MODIFIE:<nouveau total>`
  (aucun débit, stock intact). Un `acceptedTotal` invalide (≤ 0, non entier) → `invalid-argument`.
- Une application **sans** `acceptedTotal` est facturée comme avant (produits seuls, commande « historique »).
- Marketplace (AZ IA) : le texte de confirmation (`summaryFr`) est produit par le serveur et donne le total exact
  débité ; il s'affiche à l'identique dans toutes les versions de l'application.

### Activation progressive — `config/billing.separateDeliveryFee`
| Valeur | Application sans `acceptedTotal` (ancienne) | Application avec `acceptedTotal` (nouvelle) |
|---|---|---|
| `accepted_only` (**défaut** si absent/inconnu/lecture impossible) | facturation historique | nouvelle facturation |
| `required` | refusée `APP_UPDATE_REQUIRED` (aucun débit) | nouvelle facturation |
| `legacy` (coupe-circuit) | facturation historique | refusée `FACTURATION_INDISPONIBLE` (jamais sous-facturée) |

Le défaut ne change rien au déploiement : tant qu'aucune application n'envoie `acceptedTotal`, tout reste historique.
Les anciennes versions ne peuvent plus laisser le livreur payer une commission sans rémunération : voir ci-dessous.

## Commandes historiques : aucune commission sans rémunération — `config/billing.legacyPartnerAcceptance`
Une commande historique (ancienne application, sans montants explicites) n'encaisse aucun frais de livraison : le livreur
ne pourrait pas être rémunéré. Règle : AZ ne conserve jamais de commission sans contrepartie.
| Valeur | Création par une ancienne application | Acceptation d'une commande historique | Livraison d'une commande historique déjà acceptée |
|---|---|---|---|
| `block` (**défaut**) | refusée `APP_UPDATE_REQUIRED` (rien débité, stock intact) | refusée `LEGACY_PARTNER_ORDER` (livreur non débité) | commission **tracée** rendue à son payeur ; non tracée : signalée `legacyBillingReview` |
| `no_commission` (transitoire, décision d'exploitation) | acceptée (comme avant) | acceptée **sans commission** (`commissionWaivedReason`) | idem |
Aucun frais n'est inventé, aucun client n'est facturé rétroactivement, aucun vendeur n'est débité. Les commandes déjà créées
et non acceptées se résolvent dans l'écran admin « Anciennes commandes à résoudre » (`closeStuckDelivery`).
**Attention au déploiement** : avec le défaut `block`, une ancienne application Boutique ne peut plus commander. Pour ne pas
imposer de mise à jour, poser `legacyPartnerAcceptance: 'no_commission'` AVANT de déployer les fonctions.

## Stock boutique
Décrémenté à la création (transaction). Jamais restitué automatiquement lors d'une annulation, d'un remboursement client ou
admin (le produit peut être chez le client) ; seul l'échec de dispatch d'une commande cash, avant tout livreur, le restitue.
Restitution administrative : `adminBillingCF` action `confirmStockReturn` {orderId boutique, reason: `non_delivery` (livraison
annulée sans récupération) | `product_returned` (retour constaté)} — commande remboursée ou cash annulée, une seule fois
(`boutique_orders.stockReturn`), justification et audit.

## Modèle de données (additif, commandes à montants explicites)
`orders` : `amountsVersion: 1`, `productAmount`, `deliveryFee`, `totalAmount = productAmount + deliveryFee`,
`budget = deliveryFee`, `itemsAmount = productAmount`, `deliveryFeePaid` (true en wallet). `boutique_orders` : mêmes
montants, `totalPrice` = produits. Helpers : `functions/orderAmounts.js`, `functions/billingPolicy.js`.
`readAmounts()` renvoie null si les montants sont incohérents : la commande est traitée comme historique.

## Flux
| Cas | Création | Acceptation | Livraison |
|---|---|---|---|
| Wallet (marketplace / boutique) | client −total, vendeur +produits | commission 100/200 sur les frais | livreur +`deliveryFee`, vendeur non recrédité |
| Cash | rien débité | idem | aucun wallet ; `cashBreakdown` tracé (encaissé, dû vendeur, gain livreur, commission) |

## Annulation (règle commerciale)
- **Avant récupération** (pending/broadcast/assigned/accepted) : remboursement intégral (produits + livraison), vendeur
  repris des produits (plafonné), commission rendue. Boutique wallet : la commande `boutique_orders` liée est remboursée
  (`refunded`) dans la même transaction.
- **Après récupération** (`picked_up`) : produits remboursés, vendeur repris ; **frais non remboursés automatiquement** →
  `orders.deliveryFeeHold {amount, status:'pending_admin_review', driverId, …}`. La commission n'est pas rendue tant que la
  décision manque. L'argent retenu est celui déjà payé par le client : aucun paiement fictif.
- **Cash** : rien n'a été payé, rien n'est retenu ; commission rendue.
- Le message de confirmation AZ IA annonce la règle avant que le client confirme.

## Examen administratif — `adminBillingCF` (super-admin, justification ≥ 10 caractères, audit, rejouable sans effet)
- `closeStuckDelivery` {orderId, refundFee?} : clôt une livraison bloquée (annulation selon la règle ; `refundFee:true` =
  faute du livreur ou d'AZ → tout est rendu, aucune retenue). Refuse une livraison déjà livrée ou annulée.
- `resolveFeeHold` {orderId, decision} : `refundClient` (frais + commission rendus), `payDriver` (livreur +frais, commission
  conservée et journalisée), `retain` (AZ garde les frais, commission rendue). Une seule décision possible.
- `refundBoutiqueOrder` {orderId boutique} : rembourse une commande boutique wallet **dont la livraison est annulée**, sans
  attendre 48 h ; refuse si frais retenus, livraison ouverte/terminée ou déjà remboursée.
- Écran : « Facturation Marketplace » (super-admin) — frais retenus, livraisons bloquées > 2 h, boutique à rembourser.
- Le remboursement client 48 h (`refundExpiredBoutiqueOrderCF`) refuse tant que la livraison est acceptée/récupérée.

## Chemins de remboursement automatiques (extraits de `index.js` dans `functions/orderRefunds.js`)
`autoExpireOrders` (10 min sans livreur) et `enforceOrderRateLimit` : remboursement intégral des commandes non récupérées,
reprise vendeur plafonnée. Anomalie corrigée : l'annulation par limite de commandes ne reprenait pas le vendeur marketplace.

## Règles Firestore
`amountsVersion`, `deliveryFeePaid`, `cashBreakdown`, `deliveryFeeHold`, `adminReview` : interdits à la création client, non
modifiables par le livreur, le vendeur ni le client (annulation). Montants (`productAmount`, `deliveryFee`, `totalAmount`,
`itemsAmount`) verrouillés quand `amountsVersion == 1`. Les contrôles sont regroupés en un seul `diff().affectedKeys()` : la règle
`update` d'`orders` est proche de la limite de 1 000 expressions de Firestore — ne pas l'allonger sans compacter.

## Procédure de déploiement compatible avec les anciennes versions
1. Ne pas créer `config/billing` (défaut `accepted_only`). Déployer **les fonctions** : `payBoutiqueOrderCF`,
   `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`, `deliverOrderCF`, `deliverOrderWithProofCF`, `cancelOrderCF`,
   `autoExpireOrders`, `enforceOrderRateLimit`, `adminBillingCF` (nouvelle, `maxInstances:1`), et les fonctions AZ IA
   (`azIaChat`, `aiConfirmAction`). Effet : aucun changement pour les applications installées.
2. Déployer **les règles** (`firebase deploy --only firestore:rules --dry-run` d'abord).
3. Publier la nouvelle application (boutique + écran admin) sur les stores. Les nouvelles versions envoient `acceptedTotal`.
4. Suivre l'adoption (appels sans `acceptedTotal` dans `audit_logs.metadata.billing == 'legacy'`).
5. Quand les anciennes versions sont négligeables : `config/billing = { separateDeliveryFee: 'required' }`.
6. En cas de problème : `legacy` (coupe-circuit) rétablit la facturation historique ; les nouvelles applications reçoivent
   `FACTURATION_INDISPONIBLE` plutôt qu'un débit différent du total affiché.

## Décisions encore ouvertes
1. Boutique : une course annulée par `autoExpireOrders` (aucun livreur) laisse la commande `boutique_orders` « payée » jusqu'au
   remboursement client 48 h ou administratif (comportement historique ; remboursement automatique possible sur décision).
2. Restitution du stock lors d'un remboursement boutique (jamais faite aujourd'hui, ni à 48 h).
3. Partage des gains d'un éventuel transfert sur ces commandes (refusé pour l'instant).
