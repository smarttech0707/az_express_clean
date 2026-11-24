# Architecture financière des commandes Restaurant / Boulangerie — Mission 7A (préparation, NON déployée)

Branche `finalisation/az-express`. Ce document décrit l'état réel (audit Mission 7), l'outil de rapprochement, et l'architecture CIBLE des commandes versionnées. **Aucune fonction de commande, aucun écran, aucune règle Firestore, aucune fonction existante (livraison, paiement, annulation) n'est modifié.** Les orientations métier ci-dessous sont provisoires : elles ne changent aucun tarif ni parcours tant que le propriétaire ne les a pas confirmées.

## 1. État actuel (historique)
| | Restaurant | Boulangerie standard | Boulangerie gâteau sur mesure |
|---|---|---|---|
| Création | écriture directe du client | écriture directe | écriture directe |
| `budget` | total des plats | frais de livraison | frais de livraison |
| Débit wallet | à la création (`isPaid=true`) | **aucun** (`isPaid=false` même en wallet) ; `payOrderFromWalletCF` après livraison : frais seuls | à la création, `totalAmount` |
| Crédit partenaire (livraison) | `budget` | aucun | `budget` (= frais, **pas les articles**) |
| Crédit livreur | aucun | frais, seulement si le client paie après coup | aucun |
| Annulation (wallet payé) | rembourse `budget` | rien (rien débité) | rembourse `budget` seul (**articles non remboursés**) |

Conséquences (confirmées par la lecture du code, non encore mesurées en production) : articles de boulangerie jamais encaissés en wallet standard ; gâteau : articles débités mais ni versés à la boulangerie, ni remboursés ; restaurant : livreur non rémunéré en wallet et commission prélevée sur la base « total des plats ».

## 2. Outil de rapprochement (lecture seule)
- `functions/partnerOrderReconciliation.js` : fonction PURE `analyzePartnerOrders({orders, clientLedger, partnerLedger, driverLedger})`. N'écrit rien, ne propose aucune écriture, ne crée aucun remboursement. Chaque commande en anomalie reçoit une clé de décision stable `partner_reconcile_<orderId>` (une décision humaine par commande).
- `functions/scripts/partnerOrderReconciliationReport.js` : lecture Firestore (`get()` uniquement) puis rapport JSON. Exige `--project` explicite. **Non exécuté** (aucun accès à Firebase réel dans cette mission) ; à lancer plus tard sur l'émulateur ou, avec autorisation écrite, en production.
- Les commandes déjà au format versionné et les autres services (Marketplace, Boutique, etc.) sont exclus du périmètre.

| Code | Gravité | Signification |
|---|---|---|
| `CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT` | critique | produits payés par le client, partenaire non (ou partiellement) crédité |
| `WALLET_NOT_FULLY_COLLECTED` | critique | boulangerie wallet livrée dont les articles n'ont jamais été débités |
| `CANCELLED_NOT_REFUNDED`, `REFUND_INCOMPLETE`, `OVER_REFUNDED` | critique | annulation : rien / partiel / excès remboursé |
| `PARTNER_OVERCREDITED`, `PARTNER_DOUBLE_CREDIT`, `PARTNER_CREDITED_ON_CANCELLED` | critique | crédits partenaire excessifs |
| `DRIVER_FEE_UNPAID`, `DRIVER_OVERCREDITED`, `DRIVER_AND_PARTNER_BOTH_CREDITED`, `REFUND_ON_ACTIVE_ORDER`, `AMOUNT_MISMATCH` | élevée | anomalies livreur, remboursement sur commande active, produits + livraison ≠ total |
| `CASH_REMITTANCE_PENDING`, `CASH_SETTLEMENT_UNTRACED`, `LEDGER_AMOUNT_DIFFERS` | moyenne | reversement cash non confirmé ou non tracé, journal client incohérent |
| `COMMISSION_UNTRACED`, `COMMISSION_ON_PRODUCT_BASE`, `CLIENT_LEDGER_MISSING` | information | traçabilité (aucune action) |

Limites assumées : (1) pour le restaurant et le gâteau, le débit client est déduit de `isPaid=true` + règle Firestore `walletDebitMatchesPaidOrder` (le journal client est facultatif, le gâteau n'en écrit aucun) ; (2) le crédit livreur n'est visible que dans son journal `wallet_transactions` ; (3) un constat est un indice : aucune correction n'est calculée.

## 3. Architecture cible (commandes versionnées, `amountsVersion = 2`)
Module préparé : `functions/partnerOrderAmounts.js` (pur, non branché).

Champs posés par le SERVEUR à la création :
`amountsVersion: 2` · `productAmount` (produits, > 0) · `deliveryFee` (> 0, barème officiel) · `totalAmount = productAmount + deliveryFee` · `budget = deliveryFee` (le dispatch, la commission d'acceptation et les notifications livreur lisent déjà `budget` comme rémunération de la course).

Pourquoi la version 2 et non la version 1 de Marketplace/Boutique : la version 1 déclenche déjà des branches de livraison/annulation propres à ces services ; une commande partenaire ne doit jamais y être confondue. `readPartnerAmounts(order)` renvoie `null` pour tout document historique ou incohérent (traité alors comme historique).

### Séparation des quatre montants (`partnerBreakdown`)
| Montant | Formule | Destinataire |
|---|---|---|
| Payé par le client | `totalAmount` | — |
| Dû au partenaire | `productAmount` | portefeuille du restaurant / de la boulangerie |
| Rémunération brute du livreur | `deliveryFee` | livreur |
| Commission AZ | commission d'acceptation existante, **plafonnée à `deliveryFee`** | AZ (jamais sur les produits) |
| Net livreur | `deliveryFee − commission` | livreur |
Invariants testés : `clientPays = partnerDue + driverGross` ; `driverNet + azCommission = driverGross`. Cash : le livreur encaisse `totalAmount`, garde ses frais nets et doit reverser `productAmount` au partenaire (`cashToRemitToPartner`).

### Flux cible proposé (à valider, rien n'est implémenté)
1. **Devis serveur** (modèle `tariff_quotes` de la Mission 6) : prix relus dans le menu du partenaire, frais via `computeOfficialTariff` (`restaurant`/`boulangerie` déjà déclarés en barème « scale » dans `tariffConfig.js`), total = montant accepté par le client, usage unique, expiration.
2. **Création serveur** en une transaction : débit wallet du total exact (`lastPaidOrderId`, journal `order_<id>`), commande `amountsVersion: 2`.
3. **Livraison confirmée** : crédit du partenaire de `productAmount` (journal partenaire) ; livreur crédité de `deliveryFee` (commission prélevée à l'acceptation, inchangée). Cash : traçabilité du reversement (montant remis, auteur, date) au lieu du simple indicateur `merchantCashSettled`.
4. **Annulation** : avant préparation / récupération, remboursement du total exact ; commande versionnée jamais remboursée partiellement par erreur.
5. **Refus partenaire** avant préparation : annulation + remboursement sécurisé par la même voie serveur.
6. **Gâteau sur mesure** : demande sans prix → devis proposé par le boulanger → acceptation du client (c'est ce montant accepté qui est débité) → création versionnée.
7. **Historique des prix** : journal serveur (déclencheur sur `menu` / `menu_items`) : ancien prix, nouveau prix, auteur, date.

## 4. Compatibilité des commandes historiques
- Aucune commande existante n'est réécrite. Le discriminateur est `amountsVersion === 2` (valide et cohérent) ; sans lui, les chemins actuels de livraison, d'annulation et de paiement restent seuls en vigueur.
- Les commandes en cours au déploiement continuent d'être traitées par le code actuel.
- Les montants non versés des commandes historiques (articles de boulangerie, remboursements de gâteaux) sont identifiés par le rapprochement ci-dessus ; leur correction éventuelle est une décision humaine distincte, jamais automatique.
- Les nouvelles branches de livraison/annulation ne s'activeront que sur les commandes version 2.

## 5. Décisions encore nécessaires (voir rapport de mission)
Frais de livraison facturés au client pour les restaurants ; sort du texte « Livraison à partir de X » (`minDelivery`) ; moment du crédit partenaire (livraison confirmée proposée) ; traçabilité du reversement cash ; délai et refus du devis de gâteau ; wallet autorisé ou non pour la boulangerie standard avant correctif ; plafond / validation des modifications de prix ; traitement des montants historiques non versés ; refus d'une commande par le partenaire.

## 6. Ce que cette étape ne fait pas
Pas de fonction de commande restaurant/boulangerie, pas de modification des écrans, des règles Firestore, de `deliverOrderCF`, `payOrderFromWalletCF`, `cancelOrderCF`, pas de remboursement, pas de rapprochement exécuté, pas de déploiement.
